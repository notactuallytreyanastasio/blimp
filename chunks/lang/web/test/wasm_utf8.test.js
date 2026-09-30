// node --test chunks/lang/web/test/*.test.js -- the character builtins are in
// blimp.wasm too, tables and all, and a page gets the same answers the CLI
// does. The string crosses the JS/wasm boundary as UTF-8 both ways.
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const path = require('path');

const Blimp = require('../blimp.js');
const WASM = fs.readFileSync(path.join(__dirname, '..', 'blimp.wasm'));
const load = () => new Blimp().init(WASM);

test('length counts bytes, utf8_length code points, grapheme_length what a reader sees', async () => {
  const b = await load();
  const r = b.eval('[length("❤️"), utf8_length("❤️"), grapheme_length("👨‍👩‍👧‍👦🇺🇸")]');
  assert.ok(r.ok, r.error);
  assert.strictEqual(r.value, '[6, 2, 2]');
});

test('grapheme_take and utf8_upcase come back to the page intact', async () => {
  const b = await load();
  const r = b.eval('utf8_upcase(grapheme_take("straße 👋🏽 ok", 8))');
  assert.ok(r.ok, r.error);
  assert.strictEqual(r.value, '"STRASSE 👋🏽"');
});

test('ill-formed UTF-8 raises in the page as well', async () => {
  const b = await load();
  const r = b.eval('utf8_length(slice("❤️", 0, 2))');
  assert.ok(!r.ok, 'expected an error');
});
