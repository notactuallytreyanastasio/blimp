// node --test chunks/lang/web/test/*.test.js -- what blimp.wasm hands the
// page is all of it, or says what it left out. The view, the eval result,
// the error text and the message log were each written into a fixed buffer,
// and what did not fit was dropped without a word: a page of nine chess
// boards got cut-off view JSON, and mount said the program "did not produce
// a view".
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const path = require('path');

const Blimp = require('../blimp.js');
const WASM = fs.readFileSync(path.join(__dirname, '..', 'blimp.wasm'));
const load = () => new Blimp().init(WASM);
const bytes = (s) => new TextEncoder().encode(s).length;

// An actor whose view is one div of `n` squares, each with a few attrs --
// the shape of a chess board, 64 at a time.
const BOARD = (n) => `
actor Board do
  state n: Int :: ${n}
  on :view do
    reply el("div", %{class: "boards"}, map(range(1, n), fn(i: Int) -> Any do
      el("span", %{class: "sq sq-#{i}", "data-i": i, click: :pick, with: i}, "square #{i}")
    end))
  end
  on :inc(k: Int) do
    reply k
  end
end
app = spawn Board`;

test('a view tree past 64 KiB comes back whole', async () => {
  const b = await load();
  assert.ok(b.eval(BOARD(3000)).ok);
  const r = b.eval('app <- :view');
  assert.ok(r.ok, r.error);
  assert.ok(r.view, 'eval returned no view');
  const kids = r.view.children;
  assert.strictEqual(kids.length, 3000);
  assert.strictEqual(kids[2999].children[0].text, 'square 3000');
  const size = bytes(JSON.stringify(r.view));
  assert.ok(size > 65536 * 2, `view JSON is only ${size} bytes`);
});

test('a view that grows and shrinks is read from where the buffer is now', async () => {
  // The buffer moves when it grows, so a pointer read before the call is
  // stale after it. Blimp#eval reads the pointer after every call.
  const b = await load();
  assert.ok(b.eval(BOARD(10)).ok);
  assert.strictEqual(b.eval('app <- :view').view.children.length, 10);
  b.eval('big = spawn Board');
  assert.ok(b.eval(BOARD(4000)).ok);
  assert.strictEqual(b.eval('app <- :view').view.children.length, 4000);
  assert.ok(b.eval(BOARD(5)).ok);
  assert.strictEqual(b.eval('app <- :view').view.children.length, 5);
});

test('an eval result past 16 KiB comes back whole', async () => {
  const b = await load();
  const r = b.eval('range(1, 10000)');
  assert.ok(r.ok, r.error);
  assert.ok(r.value.length > 16384 * 2, `result is ${r.value.length} chars`);
  assert.ok(r.value.endsWith('9999, 10000]'), `result ends ${JSON.stringify(r.value.slice(-20))}`);
});

test('an error longer than the error buffer says it was cut', async () => {
  const b = await load();
  assert.ok(b.eval(BOARD(1)).ok);
  // A parse error in a send quotes the source, and the source holds the args.
  const r = b.send('app', 'inc', '1 + '.repeat(3000) + ')');
  assert.strictEqual(r.ok, false);
  assert.ok(r.error.startsWith('Parse error in send: app <- :inc(1 + 1 + '), r.error.slice(0, 80));
  assert.ok(r.error.endsWith('…(truncated)'), `error ends ${JSON.stringify(r.error.slice(-20))}`);
  assert.ok(bytes(r.error) <= 4096, `error is ${bytes(r.error)} bytes`);
});

test('a short error is not marked', async () => {
  const b = await load();
  const r = b.eval('nope(');
  assert.strictEqual(r.ok, false);
  assert.ok(!r.error.includes('truncated'), r.error);
});

test('a message log past its cap drops the oldest, and says how many', async () => {
  const b = await load();
  assert.ok(b.eval(BOARD(1)).ok);
  b.getState();
  const N = 6000;
  for (let i = 1; i <= N; i++) assert.ok(b.send('app', 'inc', String(i)).ok);
  const s = b.getState();
  assert.ok(s.messages.length < N, 'the cap was never reached; raise N');
  assert.strictEqual(s.messages_dropped + s.messages.length, N);
  // the newest are the ones kept
  assert.strictEqual(s.messages[s.messages.length - 1].reply, String(N));
  assert.strictEqual(s.messages[0].reply, String(s.messages_dropped + 1));
  // reading the state drains the log, and the count with it
  b.send('app', 'inc', '7');
  const s2 = b.getState();
  assert.strictEqual(s2.messages_dropped, 0);
  assert.deepStrictEqual(s2.messages.map((m) => m.reply), ['7']);
});
