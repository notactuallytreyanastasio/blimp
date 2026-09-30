// node --test chunks/lang/web/test/*.test.js -- what blimp.wasm hands the
// page is valid JSON, and when it is not, the page is told why. A view text
// holding a carriage return made the view JSON invalid, blimp.js dropped
// the parse error, and mount said the program "did not produce a view".
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const path = require('path');

const Blimp = require('../blimp.js');
const WASM = fs.readFileSync(path.join(__dirname, '..', 'blimp.wasm'));
const load = () => new Blimp().init(WASM);

// Blimp source for a string holding every byte 0x01..0x1f, and what it is.
// \e is Blimp's escape for 0x1b; the rest go into the source raw.
const CONTROL = Array.from({ length: 31 }, (_, i) => String.fromCharCode(i + 1)).join('');
const CONTROL_SRC = '"' + CONTROL.replace(/\\/g, '\\\\').replace(/"/g, '\\"') + '"';

test('a view text with a carriage return round-trips', async () => {
  const b = await load();
  const r = b.eval('el("div", nil, "a\\rb")');
  assert.ok(r.ok, r.error);
  assert.ok(r.view, 'eval returned no view');
  assert.strictEqual(r.view.children[0].text, 'a\rb');
});

test('a view text with every control character round-trips', async () => {
  const b = await load();
  const r = b.eval(`el("div", %{title: ${CONTROL_SRC}}, ${CONTROL_SRC})`);
  assert.ok(r.ok, r.error);
  assert.ok(r.view, 'eval returned no view');
  assert.strictEqual(r.view.children[0].text, CONTROL);
  assert.strictEqual(r.view.attrs.title.text, CONTROL);
});

test('a view child that is not a string is written as escaped text', async () => {
  // A map or tuple child goes through the else branch: its formatted text
  // holds quotes and backslashes, and they went into the JSON bare.
  const b = await load();
  const r = b.eval('el("div", nil, %{k: "q\\"x"}, {1, "a\\\\b"})');
  assert.ok(r.ok, r.error);
  assert.ok(r.view, 'eval returned no view');
  assert.deepStrictEqual(r.view.children.map((c) => c.text), ['%{k: "q"x"}', '{1, "a\\b"}']);
});

test('a view sent back as a reply round-trips control characters too', async () => {
  const b = await load();
  assert.ok(b.eval('actor V do\n  on :view do\n    reply el("pre", nil, "a\\rb\\ec")\n  end\nend\nv = spawn V').ok);
  const r = b.send('v', 'view');
  assert.ok(r.ok, r.error);
  assert.strictEqual(r.value.children[0].text, 'a\rb\x1bc');
});

test('completions past 32 KiB come back whole', async () => {
  const b = await load();
  const long = 'x'.repeat(4000);
  for (let i = 0; i < 10; i++) assert.ok(b.eval(`zz${i}${long} = ${i}`).ok);
  const c = b.complete('zz');
  assert.strictEqual(c.length, 10);
  assert.deepStrictEqual(c.map((e) => e.insert).sort(), Array.from({ length: 10 }, (_, i) => `zz${i}${long}`));
});

test('a test report past 64 KiB comes back whole', async () => {
  const b = await load();
  const x = b.instance.exports;
  const name = 'n'.repeat(300);
  const tests = Array.from({ length: 300 }, (_, i) => `  test "${name} ${i}" do\n    assert_eq(1, 1)\n  end`).join('\n');
  const src = `actor T do\n  state a: Int :: 0\n${tests}\nend`;
  const e = new TextEncoder().encode(src);
  const p = x.blimp_alloc(e.length);
  new Uint8Array(b.memory.buffer, p, e.length).set(e);
  const st = x.blimp_run_tests(p, e.length);
  x.blimp_free(p, e.length);
  const json = b._readString(x.blimp_get_test_report_ptr(), x.blimp_get_test_report_len());
  const report = JSON.parse(json);
  assert.strictEqual(st, 0);
  assert.strictEqual(report.total, 300);
  assert.strictEqual(report.tests.length, 300);
});

// A Blimp whose module hands back the bytes given, so the JS side can be
// held to what it does with JSON that does not parse, whatever produced it.
function fakeBlimp(bytes) {
  const b = new Blimp();
  const memory = new WebAssembly.Memory({ initial: 1 });
  const at = 1024;
  const e = new TextEncoder().encode(bytes);
  new Uint8Array(memory.buffer, at, e.length).set(e);
  b.memory = memory;
  b.instance = {
    exports: {
      memory,
      blimp_alloc: () => 8, blimp_free: () => {},
      blimp_eval: () => 0, blimp_send: () => 0, blimp_refresh_state: () => {},
      blimp_has_view: () => 1,
      blimp_get_result_ptr: () => at, blimp_get_result_len: () => e.length,
      blimp_get_view_ptr: () => at, blimp_get_view_len: () => e.length,
      blimp_get_reply_ptr: () => at, blimp_get_reply_len: () => e.length,
      blimp_get_state_ptr: () => at, blimp_get_state_len: () => e.length,
      blimp_get_error_ptr: () => at, blimp_get_error_len: () => 0,
    },
  };
  return b;
}

const BAD = '{"tag":"el","attrs":{},"children":[{"text":"a\rb"}]}';

test('eval with view JSON that does not parse says why, and where', async () => {
  const r = fakeBlimp(BAD).eval('app <- :view');
  assert.strictEqual(r.ok, false);
  assert.match(r.error, /view JSON/);
  assert.match(r.error, /position 45/);
  assert.ok(r.error.includes('"a\\rb"'), r.error); // the snippet, with the \r shown
});

test('send with a reply that does not parse returns the error, not a throw', async () => {
  const r = fakeBlimp(BAD).send('app', 'view');
  assert.strictEqual(r.ok, false);
  assert.match(r.error, /reply JSON/);
  assert.match(r.error, /position 45/);
});

test('getState with JSON that does not parse says so instead of an empty program', async () => {
  const s = fakeBlimp('{"vars":[],"actors":[{"ref":"a\rb"}]}').getState();
  assert.deepStrictEqual(s.actors, []);
  assert.match(s.error || '', /state JSON/);
});
