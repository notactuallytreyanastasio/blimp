# names are hashed once, by the parser, and that alone is a 10 to 12 percent win on Markdown and core

Nine in ten name lookups read a parameter or a local of the current frame (18.0 of 20 million on the Markdown bench), and what they paid for was not the scan, which finds the name in the innermost frame within a few bindings, but the FNV hash of the name's bytes that `lookup` computed first, every time. A parameter read in a loop body hashed its own name on every pass. The hash and the mask bit now live on the AST node.

    bench      base5 (s)             locals (s)      (three alternating rounds, user seconds)
    markdown   1.27 1.26 1.26         1.14 1.12 1.12
    core       1.85 1.85 1.86         1.62 1.62 1.62
    webtest    1.29 1.29 1.29         1.28 1.28 1.28

Base5 is the tree with the literals, scheduler, sends (lent handler state) and by-pointer evaluator changes. Markdown is 11 percent faster, core 12 percent, webtest 1 percent (it is actor-bound). The first measurement of this change, on the earlier base3, was 9 and 10 percent; the by-pointer change made the rest of the evaluator cheaper, so the hash is a larger share.

Step 1, the key (all of the gain)

`src/name_key.zig` holds `hashName`, `nameBit` (moved out of `Environment`, which re-exports them) and `Key{hash, bit}`. The parser computes a `Key` for every identifier, every `FuncCall` name, `assign_stmt` and `given_stmt` names, `for` variables and every handler/def/fn parameter (`HandlerParam.key`). `Environment.lookupKeyed` and `defineKeyed` take it; `lookup(name)` and `define(name, v)` still exist and hash for callers that only have a string. An unset key (`bit == 0`, which `nameBit` never returns) means "a node built by hand": the evaluator computes it, so the checker's and the tests' hand-made nodes behave as before. `evalFuncCall`'s `bindsLocally` mask read the bit from the call node as well.

Step 2, the inline cache (about 1.5 percent)

Each parser-made identifier also owns a `u32` hint: the offset from the innermost frame's `own_base` where the name was found last time. `lookupHinted` tries `own_base + hint` first and accepts it only if the slot is in range and holds the same hash and the same bytes; otherwise it scans and rewrites the hint. The offset is relative to `own_base` so a tail call that reuses the frame and moves `own_base` still hits. A validated slot is the right binding because a callee's own region holds each name once (`defineIn` overwrites in place), and that region is tier 1 of the lookup, ahead of captures and everything below `own_base`. Only the innermost frame is hinted; captures, caller locals and the top level take the old path.

    measured on base3: step 1 only vs step 1 + hint, alternating
    markdown   1.40 1.38 1.38   1.37 1.36 1.36
    core       2.07 2.07 2.07   2.04 2.04 2.04
    webtest    1.34 1.34 1.34   1.34 1.34 1.34

It is small and consistent, one allocation of four bytes per identifier node. It is kept; if memory per node matters more than 1.5 percent, delete it and nothing else changes. The obvious version, caching a pointer to the binding, would be wrong: bindings move when the frame's list grows, the list is recycled by `popScope`, and compaction replaces the values. An index validated on every use is none of those things.

Step 3, `defineIn` and parameter binding

Done by step 1: every parameter bind in `callClosureWithValues`, in handler dispatch, and every assignment, `given` and `for` variable take the node's key, so none of them hashes a string. What still hashes on the hot path: `collapseTo` and `lendCaptured` compute `nameBit(b.name)` per folded binding (a Binding stores the hash but not the bit; two loads and three ops, not measured separately). Handler state is lent rather than defined on this base, so it no longer hashes anything.

Not done and not worth doing here: the top-level cache from `calls.md`. Its rules (`globals_version`, the mark walk) are untouched. The 1.6 million top-level call lookups still go through `lookup`'s frame walk.

Tests (`zig build test`, all pass): a name rebound in place then read, in a tail-recursive loop and in a `for` (the same site, new frame layout each pass); one read site that resolves to a capture on one call and to a local on the next; a parameter read from a nested closure and from its own frame; a 1000-deep tail-recursive loop with a local, where `own_base` moves every pass and the frame count stays 1; and an `env.zig` test that hands `lookupHinted` a stale hint (wrong slot, past the end, unbound name) and checks the answer is still right. Note that `for` pushes a scope per pass, so a loop cannot rebind an outer name; the tests are written to what the interpreter does, not to what I first assumed.

Gates: webtest 43/0, html 646/0, core 51/0, works 160/0, reading 190/0 (cases/failures, same counts as base5); `zig build test` and `zig build wasm` pass. The Markdown bench prints the same lines as base5 apart from the millisecond numbers. `pages_show` not run: nothing here touches actors or compaction.
