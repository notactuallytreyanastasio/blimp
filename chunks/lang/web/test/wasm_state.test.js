// node --test chunks/lang/web/test -- loads web/blimp.wasm and checks the
// state JSON contract the browser hosts rely on.
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const path = require('path');

async function load() {
  const bytes = fs.readFileSync(path.join(__dirname, '..', 'blimp.wasm'));
  let mem;
  const rs = (p, l) => new TextDecoder().decode(new Uint8Array(mem.buffer, p, l));
  const { instance } = await WebAssembly.instantiate(bytes, { env: { blimp_js_print: () => {}, blimp_js_error: () => {} } });
  mem = instance.exports.memory;
  const x = instance.exports;
  x.blimp_init();
  const ev = (src) => {
    const e = new TextEncoder().encode(src); const p = x.blimp_alloc(e.length);
    new Uint8Array(mem.buffer, p, e.length).set(e);
    const st = x.blimp_eval(p, e.length); x.blimp_free(p, e.length);
    if (st !== 0) throw new Error(rs(x.blimp_get_error_ptr(), x.blimp_get_error_len()));
  };
  const state = () => JSON.parse(rs(x.blimp_get_state_ptr(), x.blimp_get_state_len()));
  return { ev, state, reset: () => x.blimp_reset() };
}

const PROG = 'actor Counter do\n  state n: Int :: 0\n  on :inc do\n    become n: n + 1\n    reply n + 1\n  end\nend\nc = spawn Counter';

test('messages accumulate across evals until the state is read', async () => {
  const b = await load();
  b.ev(PROG);
  b.state();
  b.ev('c <- :inc');
  b.ev('c <- :inc');
  const s = b.state();
  assert.deepStrictEqual(s.messages.map(m => m.message), ['inc', 'inc']);
  assert.deepStrictEqual(s.messages.map(m => m.reply), ['1', '2']);
  // reading cleared them: the next eval starts a fresh list
  b.ev('c <- :inc');
  assert.deepStrictEqual(b.state().messages.map(m => m.reply), ['3']);
});

test('a read without an eval in between returns the same messages', async () => {
  const b = await load();
  b.ev(PROG);
  b.ev('c <- :inc');
  assert.strictEqual(b.state().messages.length, 1);
  assert.strictEqual(b.state().messages.length, 1);
});

test('reset clears the accumulated messages', async () => {
  const b = await load();
  b.ev(PROG);
  b.ev('c <- :inc');
  b.reset();
  b.ev(PROG);
  assert.deepStrictEqual(b.state().messages, []);
});
