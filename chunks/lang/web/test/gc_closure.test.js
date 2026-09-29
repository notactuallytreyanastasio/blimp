// node --test chunks/lang/web/test/*.test.js -- a closure made in one eval
// and called in a later one has lived through a compaction in between (the
// WASM host compacts after every eval), so this is what a long-lived server
// that compacts between requests will do to every closure it keeps.
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const path = require('path');
const Blimp = require('../blimp.js');

async function blimp() {
  const b = new Blimp();
  b.onPrint(() => {});
  await b.init(fs.readFileSync(path.join(__dirname, '..', 'blimp.wasm')));
  return b;
}

test('a closure still sees what it captured after a compaction', async () => {
  const b = await blimp();
  assert.ok(b.eval('def make_adder(n: Int) -> Any do\n  fn(x: Int) -> Int do x + n end\nend').ok);
  assert.ok(b.eval('add5 = make_adder(5)').ok);
  const r = b.eval('add5(1)');
  assert.ok(r.ok, r.error);
  assert.strictEqual(r.value, '6');
});

test('a captured value wins over a global of the same name, after a compaction', async () => {
  const b = await blimp();
  assert.ok(b.eval('k = 100\ndef make(k: Int) -> Any do\n  fn(x: Int) -> Int do x + k end\nend\nf = make(7)').ok);
  const r = b.eval('f(1)');
  assert.ok(r.ok, r.error);
  assert.strictEqual(r.value, '8');
});
