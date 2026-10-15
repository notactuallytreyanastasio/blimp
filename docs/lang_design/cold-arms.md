# eval: move the cold arms out of line; the frame goes from 2000 to 400 bytes and the Markdown and core benches gain 1-2%

`Evaluator.eval` still carried a 1904-byte frame (2000 with saved registers) after the by-pointer change, and 5477 instructions. The disassembly of base6 shows why: every `evalX` helper with a single call site had been inlined into `evalNode`, which was inlined into `eval`. Actor definitions, try/catch, spawn, struct literals, the string-literal slow path, `locate` (with `errors.runtimeError` and its writers), the error constructors and the `Situation` temporary for `case` were all in one function, and the prologue (`sub sp, sp, #0x770`, then a `___stack_chk_guard` load and compare on exit) ran for every identifier and integer literal.

Three steps, each checked in the disassembly:

    eval frame (sub sp)             instructions in eval
    base6                0x770      5477
    noinline on 25 helpers  0x4a0   780
    cold error paths out    0x2a0   387
    evalCold split          0x150   (hot arms only)

1. `noinline` on every `evalX` helper that was being inlined (list, tuple, map, pipe, dot access, actor def, spawn, struct literal, try/catch, def, fn, for, spreads, bubble, message send, become, reply, orelse, self, string interpolation), plus `locate`.
2. The cold tails of hot arms became small `noinline` functions: `evalStringLitSlow`, `undefinedIdentifier`, `binaryOpFailed`, `notSupportedStandalone`, `evalCaseExpr`.
3. Why step 3 exists: after step 2 the frame was still 672 bytes, and almost all of it was 16-byte result slots. Zig gives each call in a switch arm its own slot for the `EvalError!*const Value` it returns, and ReleaseSafe emits no lifetime markers, so nothing is merged: 35 arms, 35 slots. Writing every arm as `res = self.evalX(x)` into one variable changed nothing (identical frame). What does work is fewer call sites. `evalNode` now keeps the arms that run per node (integer, string, bool and nil literals, identifier, given and assign, binary and unary op, call, pipe, dot access, situation and case) and sends everything else with one `else => return self.evalCold(node)`. `evalCold` has its own 384-byte frame, entered only for those nodes.

Result, ab2.sh against base6, user seconds, three rounds:

    bench             A        B
    markdown       1.16     1.15
    core           1.68     1.65
    webtest        1.32     1.32
    markdown       1.16     1.16
    core           1.68     1.65
    webtest        1.34     1.34
    markdown       1.16     1.15
    core           1.67     1.64
    webtest        1.32     1.32

About 1% on markdown, 2% on core, none on webtest. That is a small win, and smaller than the frame suggests: a 2000-byte frame costs stack, not cycles, because the prologue is a pointer bump. What each node still pays is the stack-protector guard, and that stays (below).

The stack protector, measured and not shipped. Building with `.stack_protector = false` on both modules in build.zig removes every `___stack_chk_guard` reference (3786 to 0). Against the same patch with the protector on:

    markdown 1.13 / 1.15 / 1.14  ->  1.09 / 1.11 / 1.11
    core     1.62 / 1.65 / 1.65  ->  1.54 / 1.58 / 1.57
    webtest  1.33 / 1.32 / 1.34  ->  1.33 / 1.31 / 1.33

That is 3-5% on the two eval-bound benches. It gives up detection of a stack buffer overrun in any function with an array or address-taken local, including builtins that parse program-supplied text, in a binary that runs untrusted programs from the web. build.zig is unchanged. If it is ever wanted, it should be an explicit decision with that trade written next to it.

Tried and dropped: moving float, atom and hole literals into `evalCold` shrinks the hot frame from 0x150 to 0x140 and nothing else; reverted.

Not fixed, seen: `evalBinaryOp` has a 1248-byte frame on every binary operation, from the same cause (each `self.make(.{...})` has its own Value temporary and result slot, in about 30 return sites). It is probably worth more than this patch. `callClosureWithValues` (640) and `evalTail` (400) hold the `ArgSlot` buffer on their own frames; it is not duplicated into `eval`.

Verification: `zig build test` and `zig build wasm` pass. Temper suites report zero failures with base case counts: webtest 43, html 646, core 51, works 160, reading 190. The Markdown bench prints the same 656 lines as base6 apart from the millisecond numbers. No test was added; the change moves code and has no behaviour to pin. pages_show not run (no actor or compaction change).
