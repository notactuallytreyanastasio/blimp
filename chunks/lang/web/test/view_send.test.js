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

// Just enough DOM for BlimpView to render into, patch, and count.
function fakeDocument() {
  const listeners = {};
  const el = (tag) => ({
    tag, className: '', children: [], style: {}, attrs: {}, on: {},
    get childNodes() { return this.children; },
    appendChild(c) { this.children.push(c); return c; },
    replaceChild(n, o) { this.children[this.children.indexOf(o)] = n; return o; },
    setAttribute(k, v) { this.attrs[k] = v; },
    addEventListener(type, f) { this.on[type] = f; },
    getContext() { return this.ctx || (this.ctx = fakeContext()); },
    set innerHTML(_) { this.children = []; },
    set textContent(t) { this.children = [{ text: t }]; },
  });
  const text = (t) => ({ text: t, get nodeValue() { return this.text; }, set nodeValue(v) { this.text = v; } });
  return {
    createElement: el,
    createTextNode: text,
    addEventListener(type, f) { listeners[type] = f; },
    removeEventListener(type) { delete listeners[type]; },
    fire(type, e) { listeners[type](Object.assign({ preventDefault() {} }, e)); },
  };
}

// A 2D context that writes down what it was asked to paint.
function fakeContext() {
  const calls = [];
  const rec = (name) => (...args) => calls.push([name, ...args]);
  return {
    calls,
    setTransform() {}, clearRect: rec('clear'), fillRect: rec('fillRect'), beginPath() {},
    arc: rec('arc'), fill: rec('fill'), moveTo: rec('moveTo'), lineTo: rec('lineTo'), stroke: rec('stroke'),
    fillText: rec('fillText'),
    createLinearGradient: (...args) => ({ gradient: args, stops: [], addColorStop(o, c) { this.stops.push([o, c]); } }),
    set fillStyle(v) { calls.push(['fillStyle', v]); },
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

const PADDLE = `
actor Pad do
  state y: Int :: 100
  state dir: Int :: 0
  state ai: Bool :: true
  on :up_down do
    become dir: -1
  end
  on :up_up do
    become dir: 0
  end
  on :tick do
    become y: y + dir * 10
  end
  on :toggle do
    become ai: not(ai)
  end
  on :view do
    label = case ai do
      true -> "AI"
      false -> "you"
    end
    reply stack([
      button(label, :toggle),
      key("ArrowUp", :up_down, :up_up),
      draw(200, 100, "rect 0 0 200 100 #111\ncircle 50 #{y} 5 v:#f0f,#0ff")
    ])
  end
end
pad = spawn Pad
pad <- :view`;

test('a render patches: the button and the canvas are the same elements after it', async () => {
  global.document = fakeDocument();
  const b = await blimp();
  const container = document.createElement('div');
  const view = new BlimpView(b, container, { send: true });
  assert.ok(view.mount(PADDLE, 'pad').ok);
  const [button, , canvas] = container.children[0].children;
  assert.strictEqual(canvas.tag, 'canvas');
  assert.deepStrictEqual(canvas.ctx.calls.filter((c) => c[0] === 'arc')[0].slice(1, 3), [50, 100]);
  view.send('toggle');
  view.send('tick');
  const [button2, , canvas2] = container.children[0].children;
  assert.strictEqual(button2, button, 'the button was rebuilt');
  assert.strictEqual(canvas2, canvas, 'the canvas was rebuilt');
  assert.strictEqual(textOf(button2), 'you');
  // the click handler reads what the button sends now
  button2.on.click();
  assert.strictEqual(textOf(container.children[0].children[0]), 'AI');
  view.unmount();
});

test('draw paints gradients and fails, naming the line, on a shape it does not know', async () => {
  global.document = fakeDocument();
  const b = await blimp();
  const container = document.createElement('div');
  const view = new BlimpView(b, container, { send: true });
  view.mount(PADDLE, 'pad');
  const ctx = container.children[0].children[2].ctx;
  const grad = ctx.calls.filter((c) => c[0] === 'fillStyle' && typeof c[1] === 'object')[0][1];
  assert.deepStrictEqual(grad.gradient, [45, 95, 45, 105]);
  assert.deepStrictEqual(grad.stops, [[0, '#f0f'], [1, '#0ff']]);
  view.render({ tag: 'draw', attrs: { width: { text: '10' }, height: { text: '10' }, ops: { text: 'rect 0 0 1 1 red\ntriangle 1 2 3' } }, children: [] });
  assert.match(view.error, /line 2 is not a shape draw knows.*triangle/);
});

test('a held key sends once down, not on auto-repeat, and once up', async () => {
  global.document = fakeDocument();
  const b = await blimp();
  const view = new BlimpView(b, document.createElement('div'), { send: true });
  view.mount(PADDLE, 'pad');
  const sent = [];
  view.opts.onSend = (m) => sent.push(m);
  document.fire('keydown', { key: 'ArrowUp' });
  document.fire('keydown', { key: 'ArrowUp', repeat: true });
  document.fire('keydown', { key: 'ArrowUp', repeat: true });
  view.send('tick');
  document.fire('keyup', { key: 'ArrowUp' });
  view.send('tick');
  assert.deepStrictEqual(sent, ['up_down', 'tick', 'up_up', 'tick']);
  assert.deepStrictEqual(b.send('pad', 'view').ok, true);
  view.unmount();
});
