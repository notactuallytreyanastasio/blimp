// node --test chunks/lang/web/test/*.test.js -- Blimp#runTests, which the
// tutorial's editor uses to run an exercise's tests in the page.
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const path = require('path');
const Blimp = require('../blimp.js');
const WASM = fs.readFileSync(path.join(__dirname, '..', 'blimp.wasm'));

test('runTests runs every test block and reports each one', async () => {
  const b = new Blimp();
  b.onPrint(() => {});
  await b.init(WASM);
  const r = b.runTests('actor A do\n  state n: Int :: 0\n  on :get do\n    reply n\n  end\n  test "passes" do\n    a = spawn A\n    assert_eq(a <- :get, 0)\n  end\n  test "fails" do\n    a = spawn A\n    assert_eq(a <- :get, 1)\n  end\nend\n');
  assert.strictEqual(r.total, 2);
  assert.strictEqual(r.passed, 1);
  assert.strictEqual(r.failed, 1);
  assert.strictEqual(r.ok, false);
});

test('to_html works in the browser build too', async () => {
  const b = new Blimp();
  b.onPrint(() => {});
  await b.init(WASM);
  const r = b.eval('to_html(el("li", %{class: %{note: true, fresh: true}, key: 1, click: :x}, "hi"))');
  assert.ok(r.ok, r.error);
  assert.strictEqual(r.value, '"<li class="note fresh">hi</li>"');
});
