// node --test chunks/lang/web/test
const test = require('node:test');
const assert = require('node:assert');
const R = require('../blimp-receipt.js');

const G = 'ref<Tetris.Game:9>', B = 'ref<Tetris.Board:5>', P = 'ref<Tetris.Piece:6>', S = 'ref<Tetris.Score:7>', SC = 'ref<Tetris.Screen:8>';
const m = (from, to, message, args, reply) => ({ from, target: to, message, args: args || [], reply: reply === undefined ? null : reply });
const actors = (piece, score, board) => [
  { ref: G, type: 'Tetris.Game', state: { over: 'false', paused: 'false' } },
  { ref: B, type: 'Tetris.Board', state: { rows: board || '[[0]]' } },
  { ref: P, type: 'Tetris.Piece', state: piece || { kind: '1', x: '3', y: '0', rot: '0' } },
  { ref: S, type: 'Tetris.Score', state: { score: score || '0', lines: '0', level: '1' } },
  { ref: SC, type: 'Tetris.Screen', state: {} }
];

test('splitFrames groups messages under their top-level send and drops the view cascade', () => {
  const msgs = [
    m(null, G, 'tick', [], ':ok'), m(G, G, 'gravity', [], ':ok'), m(G, B, 'fits?', ['[{3, 1}]'], 'true'),
    m(B, B, 'blocked?', ['3', '1'], 'false'), m(B, B, 'blocked?', ['4', '1'], 'false'),
    m(null, G, 'view', [], '<view_node>'), m(G, SC, 'view', ['%{}'], '<view_node>'), m(SC, SC, 'line', ['[0]'], '"x"')
  ];
  const frames = R.splitFrames(msgs);
  assert.strictEqual(frames.length, 1);
  assert.strictEqual(frames[0].head.message, 'tick');
  assert.deepStrictEqual(frames[0].sends.map(s => s.message + (s.count > 1 ? '×' + s.count : '')), ['gravity', 'fits?', 'blocked?×2']);
  assert.strictEqual(frames[0].sends[1].from, G);
  assert.strictEqual(frames[0].sends[1].reply, 'true');
});

test('stateDiffs lists fields that changed between two actor snapshots', () => {
  const before = actors({ kind: '1', x: '3', y: '0', rot: '0' }, '0');
  const after = actors({ kind: '1', x: '3', y: '1', rot: '0' }, '0');
  const d = R.stateDiffs(before, after);
  assert.deepStrictEqual(d, [{ actor: P, type: 'Tetris.Piece', field: 'y', from: '0', to: '1' }]);
  assert.deepStrictEqual(R.stateDiffs(after, after), []);
  // a new actor counts as all fields changed from nothing
  const spawned = after.concat([{ ref: 'ref<X:1>', type: 'X', state: { a: '1' } }]);
  assert.deepStrictEqual(R.stateDiffs(after, spawned), [{ actor: 'ref<X:1>', type: 'X', field: 'a', from: undefined, to: '1' }]);
});

test('isNotable skips a gravity tick that only moved the piece down', () => {
  const gravity = { head: m(null, G, 'tick'), sends: [], diffs: [{ actor: P, type: 'Tetris.Piece', field: 'y', from: '0', to: '1' }] };
  assert.strictEqual(R.isNotable(gravity), false);
  const lock = { head: m(null, G, 'tick'), sends: [], diffs: [{ actor: B, type: 'Tetris.Board', field: 'rows', from: '[[0]]', to: '[[1]]' }] };
  assert.strictEqual(R.isNotable(lock), true);
  const newPiece = { head: m(null, G, 'tick'), sends: [], diffs: [{ actor: P, type: 'Tetris.Piece', field: 'kind', from: '1', to: '4' }] };
  assert.strictEqual(R.isNotable(newPiece), true);
  const input = { head: m(null, G, 'left'), sends: [], diffs: [{ actor: P, type: 'Tetris.Piece', field: 'x', from: '3', to: '2' }] };
  assert.strictEqual(R.isNotable(input), true);
  const nothing = { head: m(null, G, 'tick'), sends: [], diffs: [] };
  assert.strictEqual(R.isNotable(nothing), false);
});

test('render produces the same shape as the native feeder, clipped to 56 columns', () => {
  const frame = {
    head: m(null, G, 'drop', [], ':ok'),
    sends: [{ from: G, to: G, message: 'drop_distance', args: ['0'], reply: '16', count: 16 }, { from: G, to: B, message: 'lock', args: ['[' + '1, '.repeat(60) + ']'], reply: ':ok', count: 1 }],
    diffs: [{ actor: S, type: 'Tetris.Score', field: 'score', from: '0', to: '32' }]
  };
  const md = R.render([frame], 'BLIMP TRACE: tetris', '10:00:00');
  assert.ok(md.startsWith('# BLIMP TRACE: tetris\n\n10:00:00\n'));
  assert.ok(md.includes('## Game#9 :drop'));
  assert.ok(md.includes('  Game#9 -> self :drop_distance(0) => 16 x16'));
  assert.ok(md.includes('  Game#9 -> Board#5 :lock(['));
  assert.ok(!/[^\x00-\x7f]/.test(md), 'receipt must be ASCII');
  assert.ok(md.includes('  * Score#7.score 0 -> 32'));
  assert.ok(md.includes('  => :ok'));
  md.split('\n').forEach(l => assert.ok(l.length <= 56, l));
});

test('Recorder captures for a window, then hands one receipt to the sender', () => {
  let now = 1000;
  const sent = [];
  const r = new R.Recorder({ sender: md => sent.push(md), seconds: 10, mode: 'everything', clock: () => now, title: 'T' });
  assert.strictEqual(r.active, false);
  r.feed({ actors: actors(), messages: [] });   // ignored while idle
  r.start();
  assert.strictEqual(r.active, true);
  r.feed({ actors: actors(), messages: [] });   // baseline snapshot
  now = 3000;
  r.feed({ actors: actors({ kind: '1', x: '3', y: '1', rot: '0' }), messages: [m(null, G, 'tick', [], ':ok'), m(G, B, 'fits?', [], 'true'), m(null, G, 'view', [], 'v')] });
  assert.strictEqual(r.frames.length, 1);
  assert.strictEqual(r.remaining(), 8);
  now = 11001;
  r.feed({ actors: actors({ kind: '1', x: '3', y: '2', rot: '0' }), messages: [m(null, G, 'tick', [], ':ok'), m(null, G, 'view', [], 'v')] });
  assert.strictEqual(r.active, false);
  assert.strictEqual(sent.length, 1);
  assert.ok(sent[0].includes('## Game#9 :tick'));
  assert.ok(sent[0].includes('Piece#6.y 0 -> 1'));
  assert.ok(sent[0].includes('Piece#6.y 1 -> 2'));
});

test('Recorder in notable mode drops gravity-only ticks and caps the receipt', () => {
  let now = 0;
  const sent = [];
  const r = new R.Recorder({ sender: md => sent.push(md), seconds: 10, mode: 'notable', clock: () => now, maxLines: 30 });
  r.start();
  r.feed({ actors: actors(), messages: [] });
  for (let i = 1; i <= 100; i++) {
    now = i * 50;
    r.feed({ actors: actors({ kind: '1', x: '3', y: String(i), rot: '0' }), messages: [m(null, G, 'tick', [], ':ok'), m(null, G, 'view', [], 'v')] });
  }
  assert.strictEqual(r.frames.length, 0);
  now = 5000;
  r.feed({ actors: actors({ kind: '2', x: '3', y: '0', rot: '0' }, '32'), messages: [m(null, G, 'tick', [], ':ok'), m(G, B, 'lock', [], ':ok'), m(null, G, 'view', [], 'v')] });
  assert.strictEqual(r.frames.length, 1);
  for (let i = 0; i < 50; i++) {
    now = 5100 + i * 50;
    r.feed({ actors: actors({ kind: '2', x: String(i), y: '0', rot: '0' }, '32'), messages: [m(null, G, 'left', [], ':ok'), m(null, G, 'view', [], 'v')] });
  }
  now = 10001;
  r.feed({ actors: actors(), messages: [] });
  assert.strictEqual(sent.length, 1);
  const lines = sent[0].split('\n');
  assert.ok(lines.length <= 30 + 4, 'lines: ' + lines.length);
  assert.ok(sent[0].includes('frames not shown'));
});
