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

async function start(t) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'bs-'));
  const port = 19000 + Math.floor(Math.random() * 2000);
  fs.writeFileSync(path.join(dir, 'site.blimp'), fs.readFileSync(PROGRAM, 'utf8').replace('__PORT__', String(port)));
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
