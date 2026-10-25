# a call to a top-level closure remembers its target, and buys 1 to 3 percent

The cache that measured zero this morning measures 1.5 percent on Markdown, 3 percent on core and 0.5 percent on webtest on base6, now that the rest of the evaluator is cheaper. The cache is correct; it is a small win and not more, because the walk it removes is short.

The assumption behind the assignment was that each top-level call walks every frame on the stack. It does not. A top-level def's frame has `globals_mark = live`, and `lookup` stops at the first frame with a mark. Counting at the two call sites in `evalFuncCall` and `evalTail` (temporary counter, not in the patch), over calls whose result is the top-level closure of that name:

    bench      top-level closure calls   avg stack depth   avg frames walked
    markdown   2,500,000 of 5,177,526    17.1              2.04
    core       6,000,000 of 8,828,621    11.0              2.35
    webtest    (under 500,000; not reported)

Frames walked, histogram for markdown, 0 to 7+: 670, 1.09M, 413k, 822k, 153k, 17k, 1.2k, 283. The stack is 11 to 17 frames deep and a lookup touches two of them. What a hit saves is the `globals.get(name)` (a string hash and a probe) and the `topFrom` chain step, not a stack walk. `topHit` itself walks the same one to three frames, testing a name bit in each, so the saving is the hash and nothing else. That is the 1 to 3 percent.

    bench      base6 (s)             calls2 (s)   (three alternating rounds, user seconds)
    markdown   1.16 1.12 1.14        1.12 1.11 1.12
    core       1.63 1.64 1.65        1.59 1.59 1.59
    webtest    1.32 1.32 1.32        1.30 1.32 1.32

The rule (`Environment.topHit`), carried over from the earlier patch

A `TopSlot` on the call site's `CallCache` holds the latest top-level binding of the name: index, value, `nameBit`, and the `globals_version` it was filled at. It may be used only when `lookup` is certain to return that binding:

1. The version is unchanged. Every top-level define bumps it, so `def f` after a call refills the slot; `reindexGlobals` bumps it, so compaction invalidates every slot. Nothing cached here lives in the code arena, so this is the only protection.
2. Walking out from the innermost frame, no frame has the name's bit in `names | captured_names`. A set bit is a false alarm at worst and sends the call down the slow path.
3. The walk stops at the first frame with a nonzero `globals_mark` (else `left_mark`), because `lookup` stops there. The slot is used only if its index is below that mark. A closure made before a redefinition has a lower mark and sees an older binding; the slot cannot say which, so that frame never uses it.

Obvious version, wrong: walking every frame after the deciding one as well. Frames outside the first marked frame cannot change the answer, and walking them made a hit as expensive as a miss.

What is different from the earlier patch. `fillTop` does not depend on how `lookup` found its answer. It reads the name's latest top-level binding and keeps it only if `topHit` then holds from where the call stands, so `lookupHinted` in env.zig is untouched (another change is editing it); the earlier patch split `lookup` into a tracking variant. A debug assertion in `lookupCall` checks that a usable slot is the pointer `lookup` returned. Only closures are remembered; a builtin keeps its existing cache.

Identifier references are not cached. The earlier count had 18 of 20 million name reads resolving to a parameter or a local and 225,000 hits for top-level identifiers; those reads are served by the slot hint. A cache would add a parser allocation per identifier for about 1 percent of reads.

Tests: redefinition between calls; a top-level def reads the live top level before its caller's locals (this looks like shadowing and is not); a capture that shadows the name at a shared `fn` literal; one `fn` literal made at two marks of the top level, called alternately; and a compaction test in gc.zig that calls through a site cached before the heap is swapped and freed. Dropping the mark check fails the two-marks test; dropping the version check fails the redefinition test and the gc test.

Gates: `zig build test`, `zig build wasm`; webtest 43, html 646, core 51, works 160, reading 190 cases, zero failures; the Markdown bench prints the same lines apart from milliseconds. pages_show not run (no actor or compaction code changed).

Not done: a call site that always resolves to a local closure (a continuation `k(...)`) refills on every miss, one `globals.get`. It showed no cost in the table, so there is no guard for it.
