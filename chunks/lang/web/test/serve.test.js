// node --test chunks/lang/web/test/*.test.js -- `blimp --serve`: one program
// that serves HTTP for as long as the process lives, collects its garbage
// between ticks, and takes code from a control socket while it runs.
// Needs the native interpreter (zig build interp).
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const net = require('net');
const http = require('http');
const { spawn } = require('child_process');

const BLIMP = path.join(__dirname, '..', '..', 'zig-out', 'bin', 'blimp');
const PROGRAM = path.join(__dirname, '..', '..', 'test', 'serve', 'hello.blimp');

function get(port) {
  return new Promise((resolve, reject) => {
    http.get({ host: '127.0.0.1', port, path: '/', agent: false }, (res) => {
      let body = '';
      res.on('data', (d) => (body += d));
      res.on('end', () => resolve(body));
    }).on('error', reject);
  });
}

function control(sock, src) {
  return new Promise((resolve, reject) => {
    const c = net.createConnection(sock, () => c.write(src + '\0'));
    let out = '';
    c.on('data', (d) => {
      out += d;
      const end = out.indexOf('\0');
      if (end >= 0) { c.end(); resolve(out.slice(0, end)); }
    });
    c.on('error', reject);
  });
}

async function start(t, program = PROGRAM) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'bs-'));
  const port = 19000 + Math.floor(Math.random() * 2000);
  fs.writeFileSync(path.join(dir, 'site.blimp'), fs.readFileSync(program, 'utf8').replace('__PORT__', String(port)));
  const proc = spawn(BLIMP, ['--serve', 'site.blimp', '--tick', 'server <- :tick', '--control', 'c.sock'], { cwd: dir });
  let log = '';
  proc.stderr.on('data', (d) => (log += d));
  t.after(() => proc.kill());
  for (let i = 0; i < 100 && !log.includes('booted'); i++) await new Promise((r) => setTimeout(r, 50));
  assert.ok(log.includes('booted'), log);
  return { port, sock: path.join(dir, 'c.sock'), proc, log: () => log };
}

test('one process serves many requests and keeps its state', async (t) => {
  const s = await start(t);
  for (let i = 1; i <= 300; i++) assert.strictEqual(await get(s.port), `hello, request ${i}\n`);
  assert.strictEqual(await control(s.sock, 'server <- :served'), '=> 300\n');
});

test('a function redefined over the control socket is used by the next request', async (t) => {
  const s = await start(t);
  assert.strictEqual(await get(s.port), 'hello, request 1\n');
  const r = await control(s.sock, 'def greeting(n: Int) -> String do\n  "changed at #{n}"\nend');
  assert.match(r, /^=> fn\(n: Int\)/);
  assert.strictEqual(await get(s.port), 'changed at 2\n');
});

test('an actor redefined over the control socket keeps its state and answers with its new code', async (t) => {
  const s = await start(t);
  assert.strictEqual(await get(s.port), 'hello, request 1\n');
  assert.strictEqual(await get(s.port), 'hello, request 2\n');
  // The same Server, with :accept answering differently and a new field.
  const program = fs.readFileSync(PROGRAM, 'utf8');
  const actor = program.slice(program.indexOf('actor Server do'), program.indexOf('server = spawn Server'));
  const v2 = actor
    .replace('state served: Int :: 0', 'state served: Int :: 0\n  state version: String :: "v2"')
    .replace('body = page(served + 1)', 'body = concat(version, " ", page(served + 1))');
  assert.notStrictEqual(v2, actor);
  assert.match(await control(s.sock, v2), /^=> /);
  assert.strictEqual(await get(s.port), 'v2 hello, request 3\n');
  assert.strictEqual(await control(s.sock, 'server <- :served'), '=> 3\n');
});

test('a failing command reports and the site keeps serving', async (t) => {
  const s = await start(t);
  const r = await control(s.sock, 'undefined_thing(1)');
  assert.match(r, /UNKNOWN FUNCTION/);
  assert.strictEqual(await get(s.port), 'hello, request 1\n');
  assert.match(await control(s.sock, ':stats'), /^ticks \d+, errors 0, /);
});

test('memory comes back down while it serves', async (t) => {
  const s = await start(t);
  const burst = async (n) => { for (let i = 0; i < n; i++) await get(s.port); };
  await burst(15000);
  const stats = await control(s.sock, ':stats');
  const compactions = Number(stats.match(/compactions (\d+)/)[1]);
  assert.ok(compactions >= 1, `no compaction after 15000 requests: ${stats}`);
  assert.strictEqual(await control(s.sock, 'server <- :served'), '=> 15000\n');
});

test('a large body reaches a slow reader whole, on a non-blocking socket', { timeout: 20000 }, async (t) => {
  const s = await start(t, path.join(__dirname, '..', '..', 'test', 'serve', 'big.blimp'));
  const got = await new Promise((resolve, reject) => {
    http.get({ host: '127.0.0.1', port: s.port, path: '/', agent: false }, (res) => {
      let n = 0;
      const expected = Number(res.headers['content-length']);
      res.on('data', (d) => {
        n += d.length;
        // read slowly, so the server's socket buffer fills
        res.pause();
        setTimeout(() => res.resume(), 2);
      });
      res.on('end', () => resolve({ n, expected }));
    }).on('error', reject);
  });
  assert.strictEqual(got.n, got.expected);
  assert.strictEqual(got.n, 2940000); // 30,000 lines of 98 bytes
});

// Slow reader, read to the end, over a raw socket: the body length and whether
// the connection ended in FIN (whole) or RST (ECONNRESET).
function slowRead(port, { requestDelayMs = 0, pauseMs = 2 } = {}) {
  return new Promise((resolve) => {
    const c = net.connect(port, '127.0.0.1');
    let head = null;
    let got = 0;
    let buf = Buffer.alloc(0);
    c.on('connect', () => setTimeout(() => c.write('GET / HTTP/1.1\r\nHost: x\r\n\r\n'), requestDelayMs));
    c.on('data', (d) => {
      if (head === null) {
        buf = Buffer.concat([buf, d]);
        const end = buf.indexOf('\r\n\r\n');
        if (end < 0) return;
        head = buf.slice(0, end).toString();
        got = buf.length - end - 4;
      } else got += d.length;
      c.pause();
      setTimeout(() => c.resume(), pauseMs);
    });
    c.on('error', (e) => resolve({ got, expected: head && Number(head.match(/Content-Length: (\d+)/)[1]), error: e.code }));
    c.on('end', () => resolve({ got, expected: Number(head.match(/Content-Length: (\d+)/)[1]), error: null }));
  });
}

test('a request the server never read does not reset the response', { timeout: 20000 }, async (t) => {
  // big.blimp reads once, as soon as it accepts. A request sent 20ms after
  // the connection opens is not there yet: it arrives while the body is being
  // written and is still unread when tcp_close runs. close() with unread input
  // sends RST, which throws away what is left in the send buffer.
  const s = await start(t, path.join(__dirname, '..', '..', 'test', 'serve', 'big.blimp'));
  const r = await slowRead(s.port, { requestDelayMs: 20 });
  assert.deepStrictEqual(r, { got: 2940000, expected: 2940000, error: null });
});

test('a 39MB body reaches a slow reader whole', { timeout: 60000 }, async (t) => {
  // A reader that keeps reading gets all of it, however many times the socket
  // buffer fills; tcp_write's deadline is real time since the last byte taken.
  const s = await start(t, path.join(__dirname, '..', '..', 'test', 'serve', 'huge.blimp'));
  const r = await slowRead(s.port);
  assert.deepStrictEqual(r, { got: 39200000, expected: 39200000, error: null });
});

test('a reader that hangs up mid-body does not take the server down', { timeout: 20000 }, async (t) => {
  const s = await start(t, path.join(__dirname, '..', '..', 'test', 'serve', 'big.blimp'));
  await new Promise((resolve) => {
    const req = http.get({ host: '127.0.0.1', port: s.port, path: '/', agent: false }, (res) => {
      res.once('data', () => { req.destroy(); resolve(); });
    });
    req.on('error', () => resolve());
  });
  await new Promise((r) => setTimeout(r, 300));
  assert.strictEqual(s.proc.exitCode, null, 'the server exited: ' + s.log());
  assert.match(await control(s.sock, ':stats'), /^ticks /);
});

test('--attach sends a last line that has no newline after it', async (t) => {
  const s = await start(t);
  assert.strictEqual(await get(s.port), 'hello, request 1\n');
  for (const input of ['server <- :served', 'server <- :served\n']) {
    const a = spawn(BLIMP, ['--attach', s.sock]);
    let out = '';
    a.stdout.on('data', (d) => (out += d));
    a.stderr.on('data', (d) => (out += d));
    a.stdin.end(input);
    const code = await new Promise((r) => a.on('close', r));
    assert.strictEqual(code, 0, `${JSON.stringify(input)}: ${out}`);
    assert.strictEqual(out, '=> 1\n', JSON.stringify(input));
  }
});
