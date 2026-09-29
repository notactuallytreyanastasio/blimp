// node --test chunks/lang/web/test/*.test.js -- blimp_send, the way a
// browser host drives an actor many times a second.
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const path = require('path');

async function load() {
  const bytes = fs.readFileSync(path.join(__dirname, '..', 'blimp.wasm'));
  let mem;
  const rs = (p, l) => new TextDecoder().decode(new Uint8Array(mem.buffer, p, l));
  const { instance } = await WebAssembly.instantiate(bytes, { env: { blimp_js_print: () => {}, blimp_js_error: () => {} } });
  mem = instance.exports.memory;
  const x = instance.exports;
  x.blimp_init();
  const put = (s) => {
    const e = new TextEncoder().encode(s);
    const p = e.length ? x.blimp_alloc(e.length) : 0;
    if (e.length) new Uint8Array(mem.buffer, p, e.length).set(e);
    return [p, e.length];
  };
  const ev = (src) => {
    const [p, n] = put(src);
    const st = x.blimp_eval(p, n); x.blimp_free(p, n);
    if (st !== 0) throw new Error(rs(x.blimp_get_error_ptr(), x.blimp_get_error_len()));
  };
  const send = (target, msg, args) => {
    const [tp, tn] = put(target), [mp, mn] = put(msg), [ap, an] = put(args || '');
    const st = x.blimp_send(tp, tn, mp, mn, ap, an);
    for (const [p, n] of [[tp, tn], [mp, mn], [ap, an]]) if (n) x.blimp_free(p, n);
    if (st !== 0) return { error: rs(x.blimp_get_error_ptr(), x.blimp_get_error_len()), status: st };
    return { reply: JSON.parse(rs(x.blimp_get_reply_ptr(), x.blimp_get_reply_len())) };
  };
  return { ev, send, mem: () => mem.buffer.byteLength, x };
}

const PROG = `
actor Box do
  state n: Int :: 0
  state name: String :: ""
  on :inc do
    become n: n + 1
    reply n + 1
  end
  on :add(k: Int) do
    become n: n + k
    reply n + k
  end
  on :name(s: String) do
    become name: s
    reply :ok
  end
  on :get do
    reply %{n: n, name: name}
  end
  on :frame(t: Float, w: Int, h: Int) do
    reply [{:fill, "#ff00ff"}, {:circle, t * 2.0, w / 2, 3.5}, [h, nil, true]]
  end
  on :weird do
    reply "quote \\" back \\\\ nl \\n tab \\t"
  end
end
box = spawn Box
`;

test('a send runs the handler and returns its reply as JSON', async () => {
  const b = await load();
  b.ev(PROG);
  assert.deepStrictEqual(b.send('box', 'inc'), { reply: 1 });
  assert.deepStrictEqual(b.send('box', 'add', '5'), { reply: 6 });
  assert.deepStrictEqual(b.send('box', 'get'), { reply: { n: 6, name: '' } });
});

test('tuples and lists are arrays, atoms are strings, nil is null', async () => {
  const b = await load();
  b.ev(PROG);
  assert.deepStrictEqual(b.send('box', 'frame', '0.25, 640, 480').reply,
    [['fill', '#ff00ff'], ['circle', 0.5, 320, 3.5], [480, null, true]]);
});

test('strings are escaped as JSON', async () => {
  const b = await load();
  b.ev(PROG);
  assert.strictEqual(b.send('box', 'weird').reply, 'quote " back \\ nl \n tab \t');
});

test('a string argument outlives the send that carried it', async () => {
  const b = await load();
  b.ev(PROG);
  b.send('box', 'name', '"sunflower"');
  for (let i = 0; i < 50; i++) b.send('box', 'inc');
  assert.strictEqual(b.send('box', 'get').reply.name, 'sunflower');
});

test('an unknown target or message is an error, not a reply', async () => {
  const b = await load();
  b.ev(PROG);
  assert.ok(b.send('nobody', 'inc').error);
  assert.ok(b.send('box', 'nope').error);
  assert.ok(b.send('box', 'add', '1, 2').error);
  // and the actor still works afterwards
  assert.deepStrictEqual(b.send('box', 'inc'), { reply: 1 });
});

test('sending does not grow memory the way eval does', async () => {
  const b = await load();
  b.ev(PROG);
  for (let i = 0; i < 2000; i++) b.send('box', 'frame', '0.5, 1280, 720');
  const before = b.mem();
  for (let i = 0; i < 20000; i++) b.send('box', 'frame', '0.5, 1280, 720');
  assert.strictEqual(b.mem(), before, `memory grew from ${before} to ${b.mem()}`);
  assert.strictEqual(b.send('box', 'inc').reply, 1);
});
