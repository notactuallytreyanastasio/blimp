// node --test chunks/lang/web/test/*.test.js -- Blimp#send and BlimpView's
// { send: true } mode, driving the real Tetris the way a page does.
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const path = require('path');

const Blimp = require('../blimp.js');
const BlimpView = require('../blimp-view.js');
const WASM = fs.readFileSync(path.join(__dirname, '..', 'blimp.wasm'));
const TETRIS = fs.readFileSync(path.join(__dirname, '..', '..', 'examples', 'tetris.blimp'), 'utf8');

// Just enough DOM for BlimpView to render into and count.
function fakeDocument() {
  const el = (tag) => ({
    tag, className: '', children: [], style: {}, attrs: {},
    appendChild(c) { this.children.push(c); return c; },
    setAttribute(k, v) { this.attrs[k] = v; },
    addEventListener() {},
    set innerHTML(_) { this.children = []; },
    set textContent(t) { this.children = [{ text: t }]; },
  });
  return {
    createElement: el,
    createTextNode: (t) => ({ text: t }),
    addEventListener() {}, removeEventListener() {},
  };
}

function textOf(node) {
  if (node.text !== undefined) return node.text;
  return (node.children || []).map(textOf).join('');
}

async function blimp() {
  const b = new Blimp();
  b.onPrint(() => {});
  await b.init(WASM);
  return b;
}

test('send returns the reply as a value', async () => {
  const b = await blimp();
  assert.ok(b.eval('actor C do\n  state n: Int :: 0\n  on :add(k: Int) do\n    become n: n + k\n    reply [n + k, :ok]\n  end\nend\nc = spawn C').ok);
  assert.deepStrictEqual(b.send('c', 'add', '2'), { ok: true, value: [2, 'ok'] });
  assert.strictEqual(b.send('c', 'nope').ok, false);
});

test("a view sent back is the same JSON eval would have produced", async () => {
  const b = await blimp();
  const mounted = b.eval(TETRIS);
  assert.ok(mounted.ok, mounted.error);
  const byEval = b.eval('game <- :view').view;
  const bySend = b.send('game', 'view').value;
  assert.deepStrictEqual(bySend, byEval);
});

test('BlimpView in send mode plays Tetris without calling eval after mount', async () => {
  global.document = fakeDocument();
  const b = await blimp();
  const container = document.createElement('div');
  const view = new BlimpView(b, container, { send: true });
  assert.ok(view.mount(TETRIS, 'game').ok);
  b.eval = () => { throw new Error('eval called after mount'); };
  const before = textOf(container);
  assert.ok(view.send('drop'));
  assert.ok(view.send('left'));
  assert.ok(view.send('tick'));
  assert.notStrictEqual(textOf(container), before);
  assert.match(textOf(container), /score \d+/);
  view.unmount();
});

test('send mode holds memory flat over a long game', async () => {
  global.document = fakeDocument();
  const b = await blimp();
  const view = new BlimpView(b, document.createElement('div'), { send: true });
  view.mount(TETRIS, 'game');
  const moves = ['tick', 'left', 'right', 'rotate', 'tick', 'down', 'drop', 'restart'];
  for (let i = 0; i < 400; i++) view.send(moves[i % moves.length]);
  const before = b.memory.buffer.byteLength;
  for (let i = 0; i < 4000; i++) view.send(moves[i % moves.length]);
  assert.strictEqual(b.memory.buffer.byteLength, before);
  view.unmount();
});
