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

// -- live streaming ---------------------------------------------------------

test('LivePrinter starts with init + bold header, streams frame lines, cuts on stop', () => {
  const sent = [];
  let now = 0;
  const lp = new R.LivePrinter({ sender: b => sent.push(b), title: 'TETRIS LIVE', clock: () => now, every: 2000, mode: 'everything' });
  lp.start();
  assert.strictEqual(sent.length, 1);
  const head = sent[0];
  assert.ok(head.startsWith('\x1b@'), 'ESC @ init');
  assert.ok(head.includes('\x1bE\x01TETRIS LIVE'), 'bold title');
  assert.ok(head.includes('\x1bM\x01'), 'font B for 56 columns');
  assert.ok(!head.includes('\x1dV'), 'no cut on start');

  lp.feed({ actors: actors(), messages: [] });   // baseline
  lp.feed({ actors: actors({ kind: '1', x: '2', y: '0', rot: '0' }), messages: [m(null, G, 'left', [], ':ok'), m(G, B, 'fits?', ['[]'], 'true'), m(null, G, 'view', [], 'v')] });
  assert.strictEqual(sent.length, 1, 'nothing flushed before the interval');
  now = 2001;
  lp.feed({ actors: actors({ kind: '1', x: '2', y: '1', rot: '0' }), messages: [m(null, G, 'tick', [], ':ok'), m(null, G, 'view', [], 'v')] });
  assert.strictEqual(sent.length, 2);
  const chunk = sent[1];
  assert.ok(chunk.includes('\x1bE\x01Game#9 :left\x1bE\x00\n'), 'bold frame heading: ' + JSON.stringify(chunk));
  assert.ok(chunk.includes('  Game#9 -> Board#5 :fits?([]) => true\n'));
  assert.ok(chunk.includes('  * Piece#6.x 3 -> 2\n'));
  assert.ok(chunk.includes('\x1bE\x01Game#9 :tick\x1bE\x00\n'), 'everything mode keeps ticks');
  assert.ok(!/[^\x00-\x7f]/.test(chunk), 'ASCII only');
  chunk.split('\n').forEach(l => assert.ok(l.replace(/\x1b./g, '').length <= 56, l));

  lp.stop();
  const tail = sent[sent.length - 1];
  assert.ok(tail.endsWith('\x1dVB\x14'), 'partial cut with feed on stop');
  assert.strictEqual(lp.active, false);
  lp.feed({ actors: actors(), messages: [m(null, G, 'left', [], ':ok')] });
  assert.strictEqual(sent.length, sent.length, 'ignored after stop');
});

test('LivePrinter in notable mode drops gravity-only ticks and flushes pending lines on stop', () => {
  const sent = [];
  let now = 0;
  const lp = new R.LivePrinter({ sender: b => sent.push(b), clock: () => now, every: 2000, mode: 'notable' });
  lp.start();
  lp.feed({ actors: actors(), messages: [] });
  lp.feed({ actors: actors({ kind: '1', x: '3', y: '1', rot: '0' }), messages: [m(null, G, 'tick', [], ':ok'), m(null, G, 'view', [], 'v')] });
  lp.feed({ actors: actors({ kind: '2', x: '3', y: '0', rot: '0' }, '32'), messages: [m(null, G, 'tick', [], ':ok'), m(G, B, 'lock', [], ':ok'), m(null, G, 'view', [], 'v')] });
  assert.strictEqual(lp.pending.filter(l => l.includes(':tick')).length, 1, 'only the locking tick');
  lp.stop();
  assert.strictEqual(sent.length, 2);
  assert.ok(sent[1].includes('Score#7.score 0 -> 32'));
  assert.ok(sent[1].endsWith('\x1dVB\x14'));
});

test('LivePrinter paces itself under the console rate limit and defers the cut', () => {
  const sent = [];
  let now = 0;
  const lp = new R.LivePrinter({ sender: b => sent.push([now, b]), clock: () => now, every: 2000, maxPerMinute: 3, mode: 'everything' });
  const frame = (msg) => ({ actors: actors(), messages: [m(null, G, msg, [], ':ok'), m(null, G, 'view', [], 'v')] });
  lp.start();                                   // post 1 (header)
  lp.feed({ actors: actors(), messages: [] });
  now = 2001; lp.feed(frame('left'));           // post 2
  now = 4002; lp.feed(frame('right'));          // post 3, window full
  assert.strictEqual(sent.length, 3);
  now = 6003; lp.feed(frame('rotate'));         // must wait: 3 posts in the last minute
  assert.strictEqual(sent.length, 3);
  assert.ok(lp.pending.length > 0);
  assert.ok(lp.waitSeconds() > 0 && lp.waitSeconds() <= 60, 'wait ' + lp.waitSeconds());
  lp.stop();                                    // wants to cut, but no slot yet
  assert.strictEqual(lp.active, false);
  assert.strictEqual(lp.closing, true);
  assert.strictEqual(sent.length, 3);
  now = 30000; lp.tick();
  assert.strictEqual(sent.length, 3, 'still inside the window');
  now = 60001; lp.tick();                       // header slot expired
  assert.strictEqual(sent.length, 4);
  assert.ok(sent[3][1].includes('Game#9 :rotate'));
  assert.ok(sent[3][1].endsWith('\x1dVB\x14'), 'pending lines and the cut go out together');
  assert.strictEqual(lp.closing, false);
  lp.tick();
  assert.strictEqual(sent.length, 4, 'nothing after the cut');
});

test('LivePrinter default pacing is twelve and a half seconds', () => {
  const lp = new R.LivePrinter({ sender: () => {} });
  assert.strictEqual(lp.every, 12500);
  assert.strictEqual(lp.maxPerMinute, 5);
});

test('LivePrinter caps a chunk and says how many lines it skipped', () => {
  const sent = [];
  let now = 0;
  const lp = new R.LivePrinter({ sender: b => sent.push(b), clock: () => now, every: 1000, maxLinesPerChunk: 12, mode: 'everything' });
  lp.start();
  lp.feed({ actors: actors(), messages: [] });
  for (let i = 0; i < 10; i++) {
    lp.feed({ actors: actors(), messages: [m(null, G, 'left', [], ':ok'), m(G, B, 'fits?', [], 'true'), m(null, G, 'view', [], 'v')] });
  }
  assert.ok(lp.pending.length > 12, 'pending grew: ' + lp.pending.length);
  now = 1001; lp.tick();
  const chunk = sent[1].split('\n').filter(l => l.length);
  assert.ok(chunk.length <= 13, 'chunk lines: ' + chunk.length);
  assert.ok(chunk[0].includes('lines skipped'), chunk[0]);
  assert.ok(chunk[chunk.length - 1].includes('=> :ok'), 'kept the newest lines');
});
