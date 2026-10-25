# a builtin call no longer walks the stack to learn that nothing binds its name, and a read inside a case arm finds its parameter by hint; Markdown 17 percent, core 13 percent

The 5.0 million hintless lookups on the Markdown bench were not hintless. Every identifier the parser makes has a hint; the hint was ignored because it was only tried in the innermost scope, and a read inside a `case` arm or a `for` body stands one to three block scopes above the frame that holds the name. Counted at the return of `lookupHinted`, by call site (temporary counters, not in the patch):

                                  markdown        core
    identifier reads              26.2M           52.0M
      hint slot, innermost        18.9M           38.2M
      scan, innermost, stale hint  1.6M            1.3M
      scan, a frame further out    5.0M           12.4M    (1 scope out 2.2M, 2 out 2.4M, 3 out 0.5M)
      lent state                   0.36M           0.16M
      top level through a mark     0.34M           0.04M
    call-name lookups              0.49M           (cache refills)
    builtin calls the bloom could not clear   2.3M   2.8M   each walked 19 frames

The mark-walk count in the intern note (3.0M) does not survive this counting: identifiers that end at a frame's `globals_mark` are 0.34M, and call names that get that far are 0.49M, walking 1.7 frames. A top-level hint on identifiers would serve 1 percent of reads; not built. The expensive item was the last row, which no earlier count showed because `lookupKeyed` was called from `builtinHit` and not from an identifier.

Three changes

1. The hint carries `frames_out << 24 | offset`. The scan writes it for any frame, provided every scope it passed reads no top-level mark. `outerHint` accepts it only if every scope above the target has neither the name's bit in `names | captured_names` nor a `globals_mark` or `left_mark`, and the slot holds the same interned pointer. Anything else falls to the scan, which gives the answer it always gave. Result: 4.65M of the 5.0M and 12.0M of the 12.4M now hit.
2. `lookupFast`, inlined into `eval`'s identifier case, is the hot path alone: innermost scope, `own_base + hint`, pointer and length equal, return. No bloom test, no hash, no stack protector. `lookupHinted` has a 0x130-byte frame and saves ten registers because the `globals` probe is inlined into it; the 19M hits paid that prologue and the guard check on exit. A hint with a frame count is a number above 2^24, which fails the `at < len` test on its own, so the fast path has no extra branch for it.
3. `Scope.stack_names` is the OR of `names | captured_names` over the scope and every scope below it (not the top level). A pushed scope copies its parent's; only the innermost scope's masks change, and `collapseTo` pops what is above `base` before anything reads, so each write to a mask adds the bit in both places. `bindsLocally` was a walk of all frames on every builtin call (8.5M calls, 19 frames, whether or not it said yes); it is one load. For the 2.3M false alarms, `unbound` replaces `lookupKeyed(...) != null`: it stops at the first frame whose `stack_names` is clear and answers "maybe bound" for any top-level binding of the name without deciding whether this frame's mark sees it, which sends the call to the general path, as before.

    bench      base8 (s)             hints (s)       (three alternating rounds, user seconds)
    markdown   0.92 0.92 0.92         0.76 0.77 0.76
    core       1.34 1.34 1.34         1.17 1.17 1.17
    webtest    1.23 1.25 1.24         1.21 1.20 1.20

After changes 1 and 2 alone: markdown 0.90 0.88 0.87, core 1.23 1.24 1.23 (3 and 7 percent). Change 3 is the other 14 and 5 percent. `lookupHinted` falls from 24 to about 4 percent of the run thread; `unbound` is 6 and is the next item.

What does not work

Stale hints still cost 1.6M and 1.3M scans. The names are `blimp_branch_NNNN`, locals of one very large generated function whose region is 45 to 60 bindings long and whose conditional assignments land at a different offset each time. The scan from the end finds them in one to three compares, so it is cheap; a hint cannot predict them.

`unbound` still compares 26 bindings per call (61M on Markdown) because large frames have most bits set. Hashing the bit from the name's FNV hash instead of first byte, last byte and length was tried and is wrong: Markdown went from 0.77 to 0.93. The old function clusters generated names onto about ten bits and leaves the rest clear for `size` and `el`; a uniform hash fills all 64. Reverted. A second mask word, or a per-bit count of live scopes, would cut the compares; I did not build either.

The pointer-only compare in `lookupFast` relies on interning for speed, not for correctness: a name at another address misses and the scan compares bytes. Tested.

Tests

`env.zig`: an outward hint is written and answered; refused when an inner scope binds the name, when a frame between it reads the top level (live mark, and an older mark that must see the old global), and when a block scope was lent the name; survives a frame whose `own_base` moves and `reindexGlobals`; `lookupFast` refuses another name's slot and accepts a copy of the right one; `stack_names` through push, pop, define, capture, and `unbound` on a shared bit, a real binding, a capture and a global. Removing the mark check or the bit check in `outerHint` fails the crossing test. `eval.zig`: reads through nested `case` arms and a `for`, a tail-recursive loop, a parameter shadowed by a callee's, a caller's local read by a top-level def until the top level gets the name, a redefinition of the function holding the read.

Gates: webtest 43/0, html 646/0, core 51/0, works 160/0, reading 190/0 (cases/failures, same counts as base8); Markdown output identical apart from timings; `zig build test` (854) and `zig build wasm` pass. `pages_show` not run: no actor or compaction code changed (`reindexGlobals` is exercised by a unit test; hints never hold top-level data).
