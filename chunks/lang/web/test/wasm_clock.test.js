// node --test chunks/lang/web/test/*.test.js -- now(), now_ms() and
// utc_offset() in the browser: WebAssembly has no clock, so blimp.js hands
// the page's in (blimp_set_clock) before every eval and send.
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const path = require('path');

const Blimp = require('../blimp.js');
const WASM = fs.readFileSync(path.join(__dirname, '..', 'blimp.wasm'));

async function blimp() {
  const b = new Blimp();
  b.onPrint(() => {});
  await b.init(WASM);
  return b;
}

test('now() is the wall clock, utc_offset() the page zone, now_ms() runs', async () => {
  const b = await blimp();
  const before = Math.floor(Date.now() / 1000);
  const r = b.eval('[now(), utc_offset(), now_ms()]');
  assert.ok(r.ok, r.error);
  const [now, offset, ms] = JSON.parse(r.value);
  assert.ok(now >= before && now <= before + 2, `now() ${now}, expected about ${before}`);
  assert.strictEqual(offset, -new Date().getTimezoneOffset() * 60);
  assert.ok(ms > 0);
});

test('the clock moves between sends', async () => {
  const b = await blimp();
  assert.ok(b.eval('actor T do\n  on :ms do\n    reply now_ms()\n  end\nend\nt = spawn T').ok);
  const a = b.send('t', 'ms').value;
  const until = Date.now() + 30; while (Date.now() < until) {}
  const c = b.send('t', 'ms').value;
  assert.ok(c - a >= 25, `now_ms() went ${a} -> ${c}`);
});

test('a host that never sets the clock reads zeros, as before', async () => {
  const { instance } = await WebAssembly.instantiate(WASM, { env: { blimp_js_print: () => {}, blimp_js_error: () => {} } });
  assert.strictEqual(typeof instance.exports.blimp_set_clock, 'function');
});
