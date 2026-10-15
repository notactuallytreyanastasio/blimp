# a builtin call whose name merely shares a bloom bit with a local no longer walks the stack and the registry; Markdown 6 percent, core 5 percent

The builtin cache on a call site was bypassed 2.3 million times on the Markdown bench and 2.8 million on core, and those are exactly the "total misses" the intern counters found. The cause is not the tail-position lookup the calls notes suspected; it is `bindsLocally`. The masks are never cleared and a name's bit is `first ^ last << 2 ^ len << 4` truncated to six bits, so a frame that has bound a handful of names says "maybe" for a good share of the rest. Counted at the cache check in `evalFuncCall` (temporary counters, not in the patch):

                                     markdown      core
    evalFuncCall calls               10.54M        19.64M
    cache valid, version stale        8.4K          1.0K
    cache valid, bloom said "bound"   2.32M         2.77M
    cache used                        6.20M        12.31M
    fell through to registry          2.33M         2.77M
    evalTail lookups that missed      0.49M         0.17M

The bloom's false alarms and the registry fall-throughs are the same number to within a few thousand: every bypass was a false alarm, none was a real shadowing builtin. A bypassed call ran the whole slow path: a lookup that walks the frames and misses, `globals.get` for the name, nine `std.mem.eql` against "map", "filter", "show", "blimp_eval" and the rest, and the registry's string hash.

The evalTail suspicion was right but small. A builtin in tail position paid one `lookupCall` miss before `eval` reached the cache (0.49M on Markdown). Both are fixed by one function, `builtinHit`: a valid cache (no top-level define since) and either a clear bloom, or a set bloom settled by a single `lookupKeyed`. A name bound nowhere is the builtin; a name bound to anything sends the call down the general path unchanged, so a closure that shadows a builtin still wins. `evalTail` asks `builtinHit` first. After the change the registry is reached 10.8K times on Markdown and 2.6K on core (first calls and redefinitions), and 2.3M and 2.8M calls pay one miss walk instead of the full path.

    bench      base7 (s)             misses A (s)    (three alternating rounds, user seconds)
    markdown   1.08 1.09 1.08         1.02 1.01 1.01
    core       1.50 1.50 1.51         1.43 1.44 1.44
    webtest    1.33 1.33 1.33         1.31 1.31 1.31

Part two, `globals` keyed by the precomputed hash, measures nothing: A against A plus the map change, three rounds:

    markdown   1.03 1.03 1.01         1.03 1.03 1.01
    core       1.46 1.46 1.42         1.44 1.45 1.41
    webtest    1.33 1.32 1.31         1.33 1.29 1.31

At most 1 percent on core, zero elsewhere. It is kept because it is correct and removes the last place that hashes a name's bytes twice, but it is a finding, not a win. `Environment.globals` is a `HashMapUnmanaged(GlobalKey, u32)` where `GlobalKey{name, hash}` carries the FNV hash the parser or the `Binding` already has; the context multiplies it by the golden-ratio constant because the map takes its fingerprint from the high bits and FNV is only good in the low ones, and compares with `sameName`. `lookupTopAt`, a lookup from a node, `fillTop`, `indexGlobal` and `reindexGlobals` (which reads each Binding's stored hash) all pass the hash; only `lookupTopAt` with a bare string hashes. The wyhash was small because the top-level hash is taken once per lookup, not once per frame, and mostly on paths the earlier patches already shortened.

Why the obvious fix would be wrong: widening or sharpening the bloom does not remove false alarms, and an exact "no frame binds this name" answer needs the frame scan the cache exists to avoid. The single lookup is that scan, but it is only paid by the 20 to 25 percent of builtin calls the bloom cannot clear, and it replaces a scan that was paid anyway.

What does not work: the remaining 2.3M and 2.8M calls still walk about three frames to learn that nothing binds the name. A cache keyed on a frame-stack version would remove that, and I did not build it; the walk is short and the table above has no room left to show it.

Gates: webtest 43/0, html 646/0, core 51/0, works 160/0, reading 190/0 (cases/failures); Markdown bench output identical apart from milliseconds; `zig build test` and `zig build wasm` pass. New test in eval.zig: `size` called with a local `sire` (same bit) from a non-tail and a tail site, then from a frame where `size` is a closure parameter. `pages_show` not run.
