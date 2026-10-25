# parameters are appended without a scan, assignments carry a slot hint, and def/fn parameters finally have a name key; Markdown 4 to 5 percent, core 1 to 2

Counting before changing anything showed where `defineIn` spends its time. On the Markdown bench there were 19.6M defines: 10.5M new names (bit clear, a plain append), 6.1M overwrites, 2.9M false alarms (bit set, name absent, so a full scan of the own region that finds nothing). Those 9.0M scans compared 102.7M bindings, 11 per scan. A third of the false alarms and all of the parameter scans were pure waste: 6.2M of the defines were parameter binds, 2.0M of them took the scan path (the 64-bit mask is crowded in big frames), and none ever found anything, because the callee's own region is empty when parameters are bound. On core the scan is shorter (32M comparisons over 14.1M scans, 2.3 each) and parameter binds are 14.5M of 38M defines. Growth of the binding buffers, the third suspect, is not a cost: 867 reallocations on Markdown, 181 on core, because recycled buffers keep their capacity. Scope pushes: 4.9M (Markdown), 11.3M (core), 29 and 31 percent of them popped with no bindings.

    bench      base7 (s)             defhint (s)     (three alternating rounds, user seconds)
    markdown   1.11 1.08 1.09         1.06 1.03 1.04
    core       1.53 1.51 1.49         1.51 1.48 1.47
    webtest    1.34 1.33 1.32         1.33 1.34 1.34

Markdown is 4 to 5 percent faster, core 1 to 2, webtest unchanged (actor-bound).

What changed

`Environment.bindParam` appends a parameter with no scan. It is used by `callClosureWithValues` and `enterHandler`. The region is empty at that point: `lendCaptured` either truncated it to `own_base` (the same closure re-entering) or moved `own_base` to the end (another callee), and a fresh scope has nothing.

The obvious version is wrong for one input: `def f(x: Int, x: Int)` parses, and the last argument has always won, because the second `define` overwrote the first. Appending both leaves two `x` in the region, and a validated slot hint can then land on the earlier one (the default hint is 0, which is exactly the first parameter). The test run printed 1 where 2 was right. The parser now marks an earlier parameter that a later one of the same name shadows (`HandlerParam.shadowed`) and the call sites skip binding it, still type-checking it. The region keeps each name once, which `lookupHinted` already relied on.

`Environment.defineHinted` is `defineKeyed` for `assign_stmt` and `given_stmt`, which now carry a `hint: ?*u32` (an assignment reuses its left-hand identifier's hint, which is never read). The hint is an offset from `own_base`, validated with `sameName` before it is trusted, and left pointing at the slot after an overwrite or an append. A loop body rebinding `acc` goes straight to the slot, and a name that was absent last time and is appended again lands at the same offset. Offsets are relative to `own_base`, so a tail call that moves it still hits. The hint never reaches below `own_base`, which has a test.

Finding: `parseTypedParamList`, which parses every `def` and `fn` parameter list, never set `HandlerParam.key`. The locals note says every parameter bind takes the node's key; it was true of handlers only. Each bind of a def or fn parameter hashed its name through `Key.of`. It is set now. I did not separate this from the append in the measurement, so the table is the three changes together.

What does not work, or was not done

The false alarms of assignments (name absent, bit set, 2.9M minus the parameter share on Markdown) still scan. A hint cannot prove absence, since another site may have bound the name earlier in the frame. A second mask word per scope would cut them, but `names` is read by `lookup` and `topHit`, which are another change's ground, so it is left. Free-list traffic for scopes that never bind (about 30 percent of pushes) could be skipped by taking a buffer lazily at the first append; the work saved is a pop and a push on a list per empty scope and I did not try it, since the counts do not make it look like 1 percent. `collapseTo` runs 384K times on Markdown folding 1.0 scope each, 1.1M times on core; not worth a fast path.

Tests added: `env.zig` `defineHinted` against a stale hint, one past the end, and one that must not reach below `own_base`; `bindParam` appends; `eval.zig` a repeated parameter name (last argument wins, closure made before a rebind keeps the old value) and a tail-recursive loop whose assignment site sees different frame layouts. The tail-call frame-reuse and capture-shadowing tests are unchanged and pass.

Gates: webtest 43/0, html 646/0, core 51/0, works 160/0, reading 190/0 (cases/failures); Markdown bench output identical apart from milliseconds; `zig build test` and `zig build wasm` pass. `pages_show` not run: nothing here touches actors or compaction.
