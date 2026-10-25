# evalBinaryOp: the frame goes from 1248 to 176 bytes and the benches gain 1-2%; the frame was never the expensive part

`evalBinaryOp` entered every one of the 5.0M (markdown) and 10.9M (core) binary operations with `sub sp, sp, #0x4e0`. coldarms had named the cause: about thirty `self.make(.{...})` return sites, each with its own Value temporary and 16-byte result slot, none merged under ReleaseSafe. `evalCompareOp` was inlined into it; `evalArithOp` had a further 448 bytes (0x1c0) and took two Values by value.

Measured in `otool -tv zig-out/bin/blimp`, `sub sp` in the prologue:

    function            base7     after
    evalBinaryOp        0x4e0     0xb0     (1248 -> 176)
    evalArithOp         0x1c0     0x1c0    (now noinline, cold, by pointer)
    evalCompareOp       inlined   noinline, no frame to speak of
    evalUnaryOp         0x70      0x70
    eval (the caller)   0x150     0x150

The path there, each step checked in the disassembly:

1. Integer fast path plus cold helpers (`evalAddSlow`, `evalConcatSlow`, `evalBinarySlow`): 0x1e0. Left alone, the new, smaller evalBinaryOp was inlined into `eval` and grew its frame from 0x150 to 0x250, which is every node of the program paying for it. It is `noinline` now.
2. Everything non-integer behind a single call to `evalBinarySlow`: 0x110. What was left was result slots: `and`/`or` evaluated the right operand at a second call site, and `makeInt` was inlined three times (add, sub, mul), each with its own `allocInt` call.
3. One `eval` call for the right operand (`and`/`or` decide after it), and the integer arms compute an `i64` that one `makeInt` turns into a pointer: 0xb0. The hot function now has four call sites: left, right, `allocInt`, `evalBinarySlow`. Booleans come from `interned.boolean`, integers in the table from `interned.intPtr`; both are new in value.zig and skip the tag switch in `interned.get`.

Equality on atoms and strings (0.6M in the Markdown bench) stays in the hot function through `eqlOut`, a `noinline` wrapper over `Value.eql`; sending it through `evalBinarySlow` would have put a 0x120 frame in front of the second most common non-integer case. Division keeps its zero and minInt/-1 handling: it goes to `evalArithOp` via `evalBinarySlow`, unchanged except that it takes `*const Value`.

Measurement
-----------

ab2.sh, three rounds, user seconds, base7 (A) against this patch (B):

    bench             A        B
    markdown       1.09     1.08
    core           1.51     1.47
    webtest        1.33     1.33
    markdown       1.08     1.06
    core           1.48     1.46
    webtest        1.31     1.31
    markdown       1.07     1.06
    core           1.50     1.47
    webtest        1.34     1.36

Markdown 1%, core 1.5-2.5%, webtest none (the 1.36 is noise; the other two rounds tie). This is the same size as the integer fast path alone measured in binops, and the same size as coldarms got for the eval frame. A 1248-byte frame costs stack, not cycles, as coldarms said: the prologue is a pointer bump. What was saved is a larger register save area on a function that now returns after a compare, and nothing more. The frame is proven smaller; it is not what the time was spent on.

What does not work
------------------

Nothing is broken. The patch is at the edge of what this machine can tell from noise, and under 2% on markdown and webtest. If the series should hold only changes that move a number clearly, this one is optional. It is kept because it leaves `evalBinaryOp` a short function whose hot path can be read, and because `evalArithOp`/`evalCompareOp` no longer copy two 24-byte Values per call.

`evalUnaryOp` is unchanged at 0x70: it has three result sites and its callers are rare. `eqlOut` has a 0x60 frame of its own because `Value.eql` takes its argument by value; changing that signature touches value.zig callers outside this assignment.

Gates
-----

`zig build test` passes, with one new test (`integer operators agree inside and outside the interned table`: results either side of the table limits 4096 and -1024, 100000 * 100000, minInt / -1 wrapping, division by zero, comparisons). `zig build wasm` passes. webtest 43, html 646, core 51, works 160, reading 190 cases, all with zero failures. The Markdown bench prints the same 656 lines as base7 apart from millisecond numbers. pages_show not run (no actor or compaction change).
