// node --test chunks/lang/web/test
const test = require('node:test');
const assert = require('node:assert');
const { Ledger } = require('../blimp-inspector.js');

const A = 'ref<Game:1>', B = 'ref<Board:2>';
function state(messages, actors) {
  return {
    vars: [],
    actors: actors || [
      { ref: A, type: 'Game', state: { over: 'false' } },
      { ref: B, type: 'Board', state: { rows: '[[0, 0]]' } }
    ],
    messages: messages
  };
}

test('feed assigns increasing seq across feeds and keeps direction', () => {
  const l = new Ledger();
  l.feed(state([{ target: A, message: 'tick', from: null, args: [], reply: ':ok' }]));
  l.feed(state([{ target: B, message: 'fits?', from: A, args: ['[{1, 2}]'], reply: 'true' }]));
  const t = l.ticker();
  assert.strictEqual(t.length, 2);
  assert.strictEqual(t[0].seq, 1);
  assert.strictEqual(t[1].seq, 2);
  assert.strictEqual(t[1].from, A);
  assert.strictEqual(t[1].to, B);
  assert.deepStrictEqual(t[1].args, ['[{1, 2}]']);
  assert.strictEqual(t[1].reply, 'true');
});

test('sent and received counts and history per actor', () => {
  const l = new Ledger();
  l.feed(state([
    { target: A, message: 'tick', from: null, args: [], reply: ':ok' },
    { target: A, message: 'gravity', from: A, args: [], reply: ':ok' },
    { target: B, message: 'fits?', from: A, args: [], reply: 'true' }
  ]));
  const game = l.actor(A), board = l.actor(B);
  assert.strictEqual(game.received, 2);
  assert.strictEqual(game.sent, 2);      // gravity to self, fits? to board
  assert.strictEqual(board.received, 1);
  assert.strictEqual(board.sent, 0);
  assert.strictEqual(game.history.length, 3);
  assert.deepStrictEqual(game.history.map(h => h.dir), ['in', 'self', 'out']);
  assert.strictEqual(board.history[0].dir, 'in');
  assert.strictEqual(board.history[0].peer, A);
});

test('actor state is the latest snapshot and unknown actors are ignored', () => {
  const l = new Ledger();
  l.feed(state([]));
  l.feed(state([{ target: 'ref<Ghost:9>', message: 'boo', from: null, args: [], reply: null }],
    [{ ref: A, type: 'Game', state: { over: 'true' } }]));
  assert.strictEqual(l.actor(A).state.over, 'true');
  assert.strictEqual(l.actor('ref<Ghost:9>'), undefined);
  assert.strictEqual(l.ticker().length, 0);
  assert.deepStrictEqual(l.actors().map(a => a.ref), [A]);
});

test('history and ticker are capped, newest kept', () => {
  const l = new Ledger({ historyCap: 3, tickerCap: 4 });
  const msgs = [];
  for (let i = 0; i < 10; i++) msgs.push({ target: A, message: 'm' + i, from: null, args: [], reply: null });
  l.feed(state(msgs));
  assert.strictEqual(l.ticker().length, 4);
  assert.strictEqual(l.ticker()[3].message, 'm9');
  assert.strictEqual(l.actor(A).history.length, 3);
  assert.strictEqual(l.actor(A).history[2].message, 'm9');
  assert.strictEqual(l.actor(A).received, 10);
});

test('feed returns the entries it added', () => {
  const l = new Ledger();
  const added = l.feed(state([{ target: A, message: 'tick', from: null, args: [], reply: null }]));
  assert.strictEqual(added.length, 1);
  assert.strictEqual(added[0].message, 'tick');
  assert.strictEqual(added[0].self, false);
});
