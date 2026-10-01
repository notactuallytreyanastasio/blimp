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
    removeChild(c) { this.children.splice(this.children.indexOf(c), 1); return c; },
    setAttribute(k, v) { this.attrs[k] = v; },
    removeAttribute(k) { delete this.attrs[k]; },
    // every listener of a type, as a real element keeps them
    addEventListener(type, f) { const hs = (this.hs = this.hs || {}); (hs[type] = hs[type] || []).push(f); this.on[type] = (e) => hs[type].forEach((h) => h(e)); },
    getContext() { return this.ctx || (this.ctx = fakeContext()); },
    setSelectionRange(a, b) { this.range = [a, b]; },
    focus() {},
    set innerHTML(v) { this.children = []; this.innerHTMLSet = v; },
    set textContent(t) { this.children = [{ text: t }]; },
  });
  const text = (t) => ({ text: t, get nodeValue() { return this.text; }, set nodeValue(v) { this.text = v; } });
  return {
    createElement: el,
    createElementNS: (ns, tag) => Object.assign(el(tag), { namespaceURI: ns }),
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

const SIZES = `
actor Board do
  state size: Int :: 4
  state name: String :: ""
  on :set_size(n: Int) do
    become size: n
  end
  on :typed(s: String) do
    become name: s
  end
  on :view do
    reply el("div", %{class: "board board-#{size}", "data-size": size},
      el("button", %{class: "mac-btn", click: :set_size, with: 8}, "8x8"),
      el("input", %{type: "text", input: :typed, value: name}),
      el("span", %{class: "who"}, "hi #{name}"))
  end
end
board = spawn Board
board <- :view`;

test('el: the page own classes, a click sends its value, typing sends the text', async () => {
  global.document = fakeDocument();
  const b = await blimp();
  const container = document.createElement('div');
  const view = new BlimpView(b, container, { send: true });
  assert.ok(view.mount(SIZES, 'board').ok);
  const div = container.children[0];
  assert.strictEqual(div.tag, 'div');
  assert.strictEqual(div.attrs.class, 'board board-4');
  assert.strictEqual(div.attrs['data-size'], '4');
  const [button, input] = div.children;
  button.on.click({ preventDefault() {} });
  assert.strictEqual(container.children[0], div, 'the div was rebuilt');
  assert.strictEqual(div.attrs.class, 'board board-8');
  input.value = 'a "quoted" #{x}';
  input.on.input();
  assert.strictEqual(textOf(div.children[2]), 'hi a "quoted" #{x}');
  assert.strictEqual(div.children[1], input, 'the input was rebuilt while typing');
  view.unmount();
});

test('el: a javascript: URL stops the view instead of rendering', async () => {
  global.document = fakeDocument();
  const b = await blimp();
  const view = new BlimpView(b, document.createElement('div'), { send: true });
  view.render({ tag: 'el', attrs: { '@tag': { text: 'a' }, href: { text: ' javascript:alert(1)' } }, children: [] });
  assert.match(view.error, /javascript: URL in href/);
});

const SWIPER = `
actor Sw do
  state moves: List :: []
  state gen: Int :: 0
  on :moved(d: Atom) do
    become moves: [d | moves], gen: gen + 1
  end
  on :view do
    reply el("div", %{class: "wrap", swipe: :moved},
      el("div", %{id: "bar-#{gen}", class: "bar"}),
      el("span", %{}, join(map(moves, fn(m: Atom) -> String do to_string(m) end), ",")))
  end
end
sw = spawn Sw
sw <- :view`;

test('el: a swipe sends its direction as an atom, and a new id is a new element', async () => {
  global.document = fakeDocument();
  const b = await blimp();
  const container = document.createElement('div');
  const view = new BlimpView(b, container, { send: true });
  assert.ok(view.mount(SWIPER, 'sw').ok);
  const wrap = container.children[0];
  const bar = wrap.children[0];
  const touch = (x, y) => ({ touches: [{ clientX: x, clientY: y }], preventDefault() {} });
  wrap.on.touchstart(touch(100, 100));
  wrap.on.touchmove(touch(95, 99));    // under 12px: nothing yet
  wrap.on.touchmove(touch(80, 101));   // left
  wrap.on.touchmove(touch(40, 101));   // the same swipe: sent once
  assert.strictEqual(textOf(wrap.children[1]), 'left');
  assert.notStrictEqual(wrap.children[0], bar, 'the bar kept its element through an id change');
  assert.strictEqual(wrap.children[0].attrs.id, 'bar-1');
  wrap.on.touchstart(touch(0, 0));
  wrap.on.touchmove(touch(2, 30));     // down
  assert.strictEqual(textOf(wrap.children[1]), 'down,left');
  view.unmount();
});

const DRAGGER = `
actor Dr do
  state x: Int :: 0
  state y: Int :: 0
  state who: String :: ""
  on :moved(w: String, dx: Int, dy: Int) do
    become x: x + dx, y: y + dy, who: w
  end
  on :view do
    reply el("div", %{class: "win", style: "translate: #{x}px #{y}px"},
      el("div", %{class: "bar", drag: :moved, with: "inbox"}, el("button", %{click: :moved}, "x")),
      el("span", %{}, "#{who} #{x},#{y}"))
  end
end
dr = spawn Dr
dr <- :view`;

test('el: a drag sends what the pointer moved, with its with, and not from a button inside', async () => {
  global.document = fakeDocument();
  const b = await blimp();
  const container = document.createElement('div');
  const view = new BlimpView(b, container, { send: true });
  assert.ok(view.mount(DRAGGER, 'dr').ok);
  const win = container.children[0];
  const bar = win.children[0];
  const ev = (x, y, target) => ({ button: 0, clientX: x, clientY: y, target: target || bar, preventDefault() {} });
  bar.on.pointerdown(ev(100, 100));
  bar.on.pointermove(ev(130, 90));
  bar.on.pointermove(ev(140, 120));
  bar.on.pointerup(ev(140, 120));
  assert.strictEqual(textOf(win.children[1]), 'inbox 40,20');
  assert.strictEqual(win.attrs.style, 'translate: 40px 20px');
  // after the pointer is up, moving it is not a drag
  bar.on.pointermove(ev(500, 500));
  assert.strictEqual(textOf(win.children[1]), 'inbox 40,20');
  // pressing the button inside the bar is the button's, not a drag
  const button = Object.assign(bar.children[0], { tagName: 'BUTTON', parentNode: bar });
  bar.on.pointerdown(ev(10, 10, button));
  bar.on.pointermove(ev(60, 60));
  assert.strictEqual(textOf(win.children[1]), 'inbox 40,20');
  view.unmount();
});

const CHATTER = `
actor Ch do
  state said: List :: []
  on :said(fields: String) do
    become said: [fields | said]
  end
  on :view do
    reply el("div", %{},
      el("div", %{class: "log", scroll: :end}, map(reverse(said), fn(s: String) -> Any do el("p", %{}, s) end)),
      el("form", %{submit: :said},
        el("textarea", %{name: "m", submit_on_enter: true}),
        el("input", %{name: "q", focus: true})))
  end
end
ch = spawn Ch
ch <- :view`;

test('el: submit_on_enter submits the form on Enter, not Shift+Enter; scroll: :end follows; focus: true focuses', async () => {
  global.document = fakeDocument();
  const b = await blimp();
  const container = document.createElement('div');
  let focused = null;
  const realCreate = document.createElement;
  document.createElement = (tag) => { const e = realCreate(tag); e.focus = () => { focused = e; }; return e; };
  const view = new BlimpView(b, container, { send: true });
  assert.ok(view.mount(CHATTER, 'ch').ok);
  const root = container.children[0];
  const log = root.children[0], form = root.children[1], area = form.children[0], input = form.children[1];
  // focus: true took the focus, nothing else having it
  assert.strictEqual(focused, input);
  // taken once: a later render does not take it back
  focused = null;
  // a real field belongs to its form, and a form submits itself
  area.form = form;
  area.value = 'hello';
  form.elements = [Object.assign(area, { name: 'm', type: 'textarea' })];
  form.requestSubmit = () => form.on.submit({ preventDefault() {} });
  let prevented = 0;
  area.on.keydown({ key: 'Enter', shiftKey: true, preventDefault() { prevented++; } });
  assert.strictEqual(textOf(log), '', 'Shift+Enter submitted');
  // the log is 500px of text in a 100px box, at its end
  Object.assign(log, { scrollHeight: 500, clientHeight: 100 });
  area.on.keydown({ key: 'Enter', shiftKey: false, preventDefault() { prevented++; } });
  assert.strictEqual(prevented, 1);
  assert.ok(textOf(log).includes('hello'));
  // the log grew a line and kept its element, and the one before is untouched
  assert.strictEqual(root.children[0], log);
  assert.strictEqual(log.scrollTop, 500);
  // the reader scrolls up to read: the next line does not pull them down
  Object.assign(log, { scrollTop: 0, scrollHeight: 600 });
  log.on.scroll();
  form.on.submit({ preventDefault() {} });
  assert.strictEqual(log.scrollTop, 0);
  // back at the end, it sticks again
  Object.assign(log, { scrollTop: 520, scrollHeight: 620 });
  log.on.scroll();
  form.on.submit({ preventDefault() {} });
  assert.strictEqual(log.scrollTop, 620);
  document.createElement = realCreate;
  view.unmount();
});

const WAITER = `
actor Wt do
  state open: Bool :: false
  on :open do
    become open: true
  end
  on :tick do
  end
  on :view do
    box = case open do
      true -> [el("textarea", %{name: "m", focus: true})]
      false -> []
    end
    reply el("div", %{}, el("button", %{click: :open}, "Open"), box)
  end
end
wt = spawn Wt
wt <- :view`;

test('el: focus: true waits while something else has the focus, then takes it once', async () => {
  global.document = fakeDocument();
  let focused = null;
  const realCreate = document.createElement;
  document.createElement = (tag) => { const e = realCreate(tag); e.focus = () => { focused = e; document.activeElement = e; }; return e; };
  const b = await blimp();
  const container = document.createElement('div');
  const view = new BlimpView(b, container, { send: true });
  assert.ok(view.mount(WAITER, 'wt').ok);
  const button = container.children[0].children[0];
  // the click that opens the box leaves the focus on the button
  document.activeElement = button;
  button.on.click({ preventDefault() {} });
  const box = container.children[0].children[1];
  assert.strictEqual(focused, null, 'took the focus from the button');
  // the button goes, but the box is disabled (someone is typing to you): it waits
  document.activeElement = null;
  box.disabled = true;
  view.send('tick');
  assert.strictEqual(focused, null);
  // enabled, the next render gives it the focus
  box.disabled = false;
  view.send('tick');
  assert.strictEqual(focused, box);
  // once: after the reader moves on, it is not pulled back
  document.activeElement = null; focused = null;
  view.send('tick');
  assert.strictEqual(focused, null);
  document.createElement = realCreate;
  view.unmount();
});

const LISTER = `
actor Li do
  state n: Int :: 3
  on :set(k: Int) do
    become n: k
  end
  on :view do
    reply el("ul", %{}, map(range(1, n), fn(i: Int) -> Any do el("li", %{id: "i#{i}"}, "#{i}") end))
  end
end
li = spawn Li
li <- :view`;

test('el: a list that grows or shrinks keeps its element and the children it still has', async () => {
  global.document = fakeDocument();
  const b = await blimp();
  const container = document.createElement('div');
  const view = new BlimpView(b, container, { send: true });
  assert.ok(view.mount(LISTER, 'li').ok);
  const ul = container.children[0];
  const [one, two] = ul.children;
  view.send('set', '5');
  assert.strictEqual(container.children[0], ul);
  assert.strictEqual(ul.children.length, 5);
  assert.strictEqual(ul.children[0], one);
  assert.strictEqual(textOf(ul), '12345');
  view.send('set', '2');
  assert.strictEqual(container.children[0], ul);
  assert.deepStrictEqual(ul.children, [one, two]);
  view.unmount();
});

const WIRE = `
def wdrop(l: List, k: Int) -> List do
  case k <= 0 or l == [] do
    true -> l
    false -> wdrop(tail(l), k - 1)
  end
end

actor Wire do
  state got: List :: []
  state ups: Int :: 0
  state downs: Int :: 0
  state first: Int :: 1
  state out: List :: []
  on :say(t: String) do
    become out: append(out, t)
  end
  on :frame(t: String) do
    become got: append(got, t)
  end
  on :up do
    become ups: ups + 1
  end
  on :down do
    become downs: downs + 1
  end
  on :sent(n: Int) do
    become out: wdrop(out, n - first + 1), first: n + 1
  end
  on :view do
    reply el("div", %{},
      socket("/live/w", %{frame: :frame, open: :up, closed: :down, sent: :sent}, first, out),
      el("span", %{}, concat("#{ups}/#{downs} got=", join(got, ","), " out=#{length(out)} first=#{first}")))
  end
end
w = spawn Wire
w <- :view`;

test('socket(): frames out once each and in order, frames in in order, a drop redials, unmount hangs up', async () => {
  global.document = fakeDocument();
  const made = [];
  global.WebSocket = class {
    constructor(url) { this.url = url; this.readyState = 0; this.sent = []; made.push(this); }
    send(d) { this.sent.push(d); }
    close() { this.readyState = 3; this.closed = true; }
  };
  const tick = (ms) => new Promise((r) => setTimeout(r, ms || 5));
  const b = await blimp();
  const container = document.createElement('div');
  const view = new BlimpView(b, container, { send: true });
  assert.ok(view.mount(WIRE, 'w').ok);
  const status = () => textOf(container.children[0].children[1]);
  assert.strictEqual(made.length, 1);
  assert.strictEqual(made[0].url, 'ws:///live/w');
  // said before it is open: it waits
  view.send('say', '"a"');
  assert.deepStrictEqual(made[0].sent, []);
  made[0].readyState = 1;
  made[0].onopen();
  assert.deepStrictEqual(made[0].sent, ['a']);
  await tick();
  assert.strictEqual(status(), '1/0 got= out=0 first=2');
  // open: straight out, and never twice, however often it renders
  view.send('say', '"b"');
  view.send('say', '"c"');
  await tick();
  view.send('say', '"d"');
  await tick();
  assert.deepStrictEqual(made[0].sent, ['a', 'b', 'c', 'd']);
  assert.strictEqual(status(), '1/0 got= out=0 first=5');
  // frames in, in the order they came
  made[0].onmessage({ data: 'x' });
  made[0].onmessage({ data: 'y' });
  made[0].onmessage({ data: 'z' });
  await tick();
  assert.strictEqual(status(), '1/0 got=x,y,z out=0 first=5');
  // a drop: said, and redialled; what was said meanwhile goes on reconnect
  made[0].readyState = 3;
  made[0].onclose();
  view.send('say', '"e"');
  await tick();
  assert.strictEqual(status(), '1/1 got=x,y,z out=1 first=5');
  await tick(560);
  assert.strictEqual(made.length, 2);
  made[1].readyState = 1;
  made[1].onopen();
  assert.deepStrictEqual(made[1].sent, ['e']);
  await tick();
  assert.strictEqual(status(), '2/1 got=x,y,z out=0 first=6');
  // unmount hangs up and does not redial
  view.unmount();
  assert.ok(made[1].closed);
  await tick(600);
  assert.strictEqual(made.length, 2);
  delete global.WebSocket;
});

const TYPER = `
actor Typer do
  state text: String :: ""
  state open: Bool :: true
  on :typed(k: String) do
    become text: concat(text, k)
  end
  on :toggle do
    become open: not(open)
  end
  on :view do
    modal = case open do
      true -> [el("div", %{class: "backdrop", click: :toggle}, el("button", %{click: :toggle}, "Close"))]
      false -> []
    end
    reply el("div", %{}, el("pre", %{}, text), modal, key("*", :typed))
  end
end
typer = spawn Typer
typer <- :view`;

test('key("*") sends every key as a string; a nested click fires only the innermost', async () => {
  global.document = fakeDocument();
  const b = await blimp();
  const container = document.createElement('div');
  const view = new BlimpView(b, container, { send: true });
  assert.ok(view.mount(TYPER, 'typer').ok);
  for (const key of ['h', 'i', '"', '#', '{']) document.fire('keydown', { key });
  assert.strictEqual(textOf(container.children[0].children[0]), 'hi"#{');
  const backdrop = container.children[0].children[1];
  const close = backdrop.children[0];
  let stopped = false;
  const ev = { preventDefault() {}, stopPropagation() { stopped = true } };
  close.on.click(ev);
  if (!stopped) backdrop.on.click(ev);   // what a real DOM would do next
  assert.strictEqual(container.children[0].children.length, 2, 'the modal toggled twice and stayed open');
  view.unmount();
});

const EDITOR = `
actor Ed do
  state text: String :: "é!"
  state sel: String :: "0,0"
  state got: List :: []
  on :typed(s: String) do
    become text: s
  end
  on :moved(a: Int, b: Int) do
    become got: [a, b]
  end
  on :key(k: String) do
    become text: concat(text, k), sel: "2,4"
  end
  on :view do
    reply el("div", %{},
      el("textarea", %{value: text, input: :typed, debounce: 30, select: :moved, selection: sel, shortcut: :key, shortcut_keys: "bi"}),
      el("div", %{class: "preview", inner_html: "<p>hi</p>"}),
      el("span", %{}, join(map(got, fn(n: Int) -> String do to_string(n) end), ",")))
  end
end
ed = spawn Ed
ed <- :view`;

test('a field: selection in bytes both ways, shortcuts, debounced input, inner_html', async () => {
  global.document = fakeDocument();
  const b = await blimp();
  const container = document.createElement('div');
  const view = new BlimpView(b, container, { send: true });
  assert.ok(view.mount(EDITOR, 'ed').ok);
  const [ta, preview, out] = container.children[0].children;
  assert.strictEqual(preview.innerHTMLSet, '<p>hi</p>');
  // the browser's selection is UTF-16: "é!" selecting "!" is 1..2, bytes 2..3
  ta.value = 'é!'; ta.selectionStart = 1; ta.selectionEnd = 2;
  ta.on.select();
  assert.strictEqual(textOf(out), '2,3');
  // a shortcut the program asked for is sent and prevented; others are not
  let prevented = 0;
  ta.on.keydown({ key: 'b', metaKey: true, preventDefault() { prevented++ } });
  ta.on.keydown({ key: 'c', metaKey: true, preventDefault() { prevented++ } });
  assert.strictEqual(prevented, 1);
  // the program set selection "2,4" in bytes of "é!b": UTF-16 1..3
  const t2 = container.children[0].children[0];
  assert.deepStrictEqual(t2.range, [1, 3]);
  // input waits for the pause
  t2.value = 'typed';
  t2.on.input(); t2.on.input();
  assert.strictEqual(t2.attrs.value, 'é!b');
  await new Promise((r) => setTimeout(r, 60));
  assert.strictEqual(container.children[0].children[0].attrs.value, 'typed');
  view.unmount();
});

const FETCHER = `
actor Songs do
  state year: String :: "2023"
  state body: String :: ""
  state status: Int :: -1
  on :got(s: Int, b: String) do
    become status: s, body: b
  end
  on :pick(y: String) do
    become year: y, body: "", status: -1
  end
  on :view do
    asks = case body do
      "" -> [fetch(concat("/songs.json?year=", year), :got)]
      _ -> []
    end
    reply el("div", %{}, el("p", %{}, concat(to_string(status), " ", body)), asks, location_query(concat("year=", year)))
  end
end
songs = spawn Songs
songs <- :view`;

const KEEPER = `
actor Kp do
  state name: String :: "?"
  state reads: Int :: 0
  state ask: Bool :: true
  on :recalled(v: String) do
    become name: v, reads: reads + 1
  end
  on :rename(v: String) do
    become name: v
  end
  on :forget do
    become ask: false
  end
  on :view do
    asking = case ask do
      true -> [stored("kp.name", :recalled)]
      false -> []
    end
    reply el("div", %{}, el("span", %{}, "#{name}/#{reads}"), asking, store("kp.name", name))
  end
end
kp = spawn Kp
kp <- :view`;

test('stored() reads localStorage once and sends it; store() writes what the view says', async () => {
  global.document = fakeDocument();
  const mem = { 'kp.name': 'alice' };
  global.localStorage = {
    getItem: (k) => (k in mem ? mem[k] : null),
    setItem: (k, v) => { mem[k] = String(v); },
    removeItem: (k) => { delete mem[k]; },
  };
  const b = await blimp();
  const container = document.createElement('div');
  const view = new BlimpView(b, container, { send: true });
  assert.ok(view.mount(KEEPER, 'kp').ok);
  await new Promise((r) => setTimeout(r, 10));
  const root = container.children[0];
  // read once, after the first render; not again on the next renders
  assert.strictEqual(textOf(root.children[0]), 'alice/1');
  view.send('rename', '"bob"');
  await new Promise((r) => setTimeout(r, 10));
  assert.strictEqual(textOf(root.children[0]), 'bob/1');
  assert.strictEqual(mem['kp.name'], 'bob');
  // "" removes it
  view.send('rename', '""');
  assert.ok(!('kp.name' in mem));
  // storage that refuses (a private window) reads "" and drops writes
  global.localStorage = { getItem() { throw new Error('denied'); }, setItem() { throw new Error('denied'); }, removeItem() {} };
  view.send('rename', '"carol"');
  assert.strictEqual(textOf(root.children[0]), 'carol/1');
  view.unmount();
  delete global.localStorage;
});

test('fetch() asks the host once while it is in the view; location_query() keeps the URL', async () => {
  global.document = fakeDocument();
  const asked = [];
  global.fetch = (url) => { asked.push(url); return Promise.resolve({ status: 200, text: () => Promise.resolve('{"n": "\\"#{x}"}') }) };
  global.location = { pathname: '/phish', search: '' };
  global.history = { replaceState: (_s, _t, u) => { global.location.search = u.startsWith('?') ? u : '' } };
  const b = await blimp();
  const container = document.createElement('div');
  const view = new BlimpView(b, container, { send: true });
  assert.ok(view.mount(FETCHER, 'songs').ok);
  assert.strictEqual(global.location.search, '?year=2023');
  await new Promise((r) => setTimeout(r, 20));
  assert.deepStrictEqual(asked, ['/songs.json?year=2023']);
  assert.strictEqual(textOf(container.children[0].children[0]), '200 {"n": "\\"#{x}"}');
  view.send('pick', '"2016"');
  await new Promise((r) => setTimeout(r, 20));
  assert.deepStrictEqual(asked, ['/songs.json?year=2023', '/songs.json?year=2016']);
  assert.strictEqual(global.location.search, '?year=2016');
  view.unmount();
  delete global.fetch; delete global.location; delete global.history;
});

test('el: everything inside an <svg> is made in the SVG namespace, <title> included', async () => {
  global.document = fakeDocument();
  const b = await blimp();
  const container = document.createElement('div');
  const view = new BlimpView(b, container, { send: true });
  view.render({ tag: 'el', attrs: { '@tag': { text: 'div' } }, children: [
    { tag: 'el', attrs: { '@tag': { text: 'svg' } }, children: [
      { tag: 'el', attrs: { '@tag': { text: 'rect' } }, children: [
        { tag: 'el', attrs: { '@tag': { text: 'title' } }, children: [{ text: 'tip' }] }] }] },
    { tag: 'el', attrs: { '@tag': { text: 'title' } }, children: [] }] });
  const [svg, htmlTitle] = container.children[0].children;
  const title = svg.children[0].children[0];
  assert.strictEqual(title.namespaceURI, 'http://www.w3.org/2000/svg');
  assert.strictEqual(htmlTitle.namespaceURI, undefined);
});

test('el: an attr that is nil is left off, in the browser as in to_html', async () => {
  global.document = fakeDocument();
  const b = await blimp();
  const container = document.createElement('div');
  const view = new BlimpView(b, container, { send: true });
  assert.ok(view.mount(`
actor Bars do
  on :view do
    reply el("div", %{}, el("button", %{"data-full": nil, title: "a"}), el("button", %{"data-full": true}))
  end
end
bars = spawn Bars
bars <- :view`, 'bars').ok);
  const [a, bb] = container.children[0].children;
  assert.strictEqual('data-full' in a.attrs, false);
  assert.strictEqual(a.attrs.title, 'a');
  assert.strictEqual(bb.attrs['data-full'], '');
  view.unmount();
});

test('what blimp.send does shows in getState: actors as they are, and the messages', async () => {
  const b = await blimp();
  assert.ok(b.eval('actor Inner do\n  state n: Int :: 0\n  on :ping do\n    become n: n + 1\n    reply :pong\n  end\nend\nactor Outer do\n  state inner: Any :: nil\n  on :start do\n    become inner: spawn Inner\n    reply :ok\n  end\n  on :go do\n    reply inner <- :ping\n  end\nend\no = spawn Outer\no <- :start').ok);
  b.getState();
  assert.deepStrictEqual(b.send('o', 'go'), { ok: true, value: 'pong' });
  b.send('o', 'go');
  const s = b.getState();
  assert.deepStrictEqual(s.messages.map((m) => m.message), ['go', 'ping', 'go', 'ping']);
  assert.strictEqual(s.actors.find((a) => a.type === 'Inner').state.n, '2');
  assert.deepStrictEqual(b.getState().messages, []);
});
