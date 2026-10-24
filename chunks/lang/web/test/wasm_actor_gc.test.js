// node --test chunks/lang/web/test/*.test.js -- the browser build drops
// actors nothing can reach, as `blimp --serve` does. It used to keep every
// actor ever spawned: Snake compiled from Temper (every object an actor)
// carried 877,590 of them and 104 MB after 100 restarts, and a frame took
// 128 ms instead of 2.
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const path = require('path');

const Blimp = require('../blimp.js');
const WASM = fs.readFileSync(path.join(__dirname, '..', 'blimp.wasm'));

// A game in the shape Temper compiles to: every point is an actor, every
// tick makes new ones and lets the old ones go, a restart throws away the
// whole board. What must survive is what something can still name: the
// board through the game's state, the cells through a list in the board's
// state, an actor held only by a closure, one held in a map in a list.
const PROG = `
actor Cell do
  state v: Int :: 0
  on :v do reply v end
end
def cells(n: Int, base: Int, acc: Any) -> Any do
  case n == 0 do
    true -> acc
    false ->
      c = spawn(Cell, v: base + n)
      cells(n - 1, base, [c | acc])
  end
end
def total(cs: Any, acc: Int) -> Int do
  case cs == [] do
    true -> acc
    false -> total(tail(cs), acc + (head(cs) <- :v))
  end
end
actor Board do
  state cs: Any :: []
  state t: Int :: 0
  on :tick do
    become cs: cells(20, t + 1, []), t: t + 1
    reply t + 1
  end
  on :total do reply total(cs, 0) end
end
actor Game do
  state board: Any :: nil
  state keep: Any :: nil
  on :restart do
    b = spawn Board
    b <- :tick
    become board: b
    reply :ok
  end
  on :tick do reply board <- :tick end
  on :total do reply board <- :total end
  on :hold(x: Any) do become keep: x end
  on :kept do reply (head(keep) <- :v) end
end
app = spawn Game
app <- :restart
app <- :hold([spawn(Cell, v: 7)])
lone = spawn(Cell, v: 41)
by_closure = fn() do lone end
lone = nil
nested = [%{c: spawn(Cell, v: 5)}]
:ready
`;

async function load() {
  const b = await new Blimp().init(WASM);
  b.onPrint(() => {}); b.onError(() => {});
  const r = b.eval(PROG);
  assert.ok(!r.error, 'program did not load: ' + r.error);
  return b;
}

function ev(b, src) {
  const r = b.eval(src);
  assert.ok(r.ok, `${src} failed: ${r.error}`);
  return r.value;
}

function send(b, target, msg, args) {
  const r = b.send(target, msg, args || '');
  assert.ok(r.ok, `${target} <- :${msg} failed: ${r.error}`);
  return r.value;
}

test('a long run that drops actors keeps a flat heap and a flat actor count', async () => {
  const b = await load();
  const x = b.instance.exports;
  const run = (restarts, ticks) => {
    for (let r = 0; r < restarts; r++) {
      send(b, 'app', 'restart');
      for (let t = 0; t < ticks; t++) send(b, 'app', 'tick');
    }
  };
  // Warm up: the arenas and the wasm memory reach their size. Measured: one
  // 64 KiB page more by 100 restarts, then none in the next 2,900.
  run(100, 20);
  const mem = x.memory.buffer.byteLength;
  const heap = x.blimp_heap_bytes();
  run(200, 20); // 200 boards and 84,000 cells made and let go
  assert.strictEqual(x.memory.buffer.byteLength, mem, `wasm memory grew from ${mem} to ${x.memory.buffer.byteLength}`);
  assert.ok(x.blimp_heap_bytes() <= heap * 2, `heap grew from ${heap} to ${x.blimp_heap_bytes()}`);
  const st = b.getState();
  assert.ok(!st.error, st.error);
  // 200 * 21 * 20 cells were spawned; one board's worth (plus garbage the
  // next compaction drops, at most twice the live set) is all that is left.
  assert.ok(st.actors.length < 100, `${st.actors.length} actors alive after 84,000 were dropped`);
  // The live board still answers: its cells are reachable through a list in
  // its state, which is reachable through the game's state.
  // Board t=21 holds cells 22..41 (t+1 + n for n = 1..20): sum is 630.
  assert.strictEqual(send(b, 'app', 'total'), 630);
});

test('what the host and the program can still name survives compaction', async () => {
  const b = await load();
  for (let i = 0; i < 500; i++) send(b, 'app', 'tick');
  send(b, 'app', 'restart');
  for (let i = 0; i < 500; i++) send(b, 'app', 'tick');
  // through an actor's state, a list in it
  assert.strictEqual(send(b, 'app', 'kept'), 7);
  // through a closure only
  assert.strictEqual(ev(b, 'by_closure() <- :v'), '41');
  // through a map inside a list in a binding
  assert.strictEqual(ev(b, 'lookup(head(nested), :c) <- :v'), '5');
  // bound at the top level
  assert.strictEqual(send(b, 'app', 'tick'), 502);
  // a ref printed and then dropped names nothing: it is not someone else
  const st = b.getState();
  const ids = st.actors.map((a) => a.ref);
  assert.strictEqual(new Set(ids).size, ids.length);
});
