# eval: take the node by pointer and capture switch payloads by pointer; 16-19% off the Markdown and core benches

`Evaluator.eval` was not copying the 104-byte `ast.Node` into its argument. Zig already passes a large const parameter by reference, and the base's disassembly shows the node arriving as a pointer in x2. What it did copy was the payload. `evalNode` had been inlined into `eval`, and the switch arms captured by value (`.string_lit => |lit|`, `.binary_op => |op|`), so the prologue loaded the node's 96-byte `kind` union into registers and stack slots, spilled it, and then dispatched. That happens once per node evaluated, before the tag is even looked at. The frame of `eval` was 0x980 bytes (2432); with pointer captures it is 0x6e0 (1760), and the prologue is a tag load and a jump table.

Measured with ab2.sh against the integrated base (literals, scheduler and sends changes already in it), user seconds, three rounds:

    bench             A        B
    markdown       1.51     1.27
    core           2.32     1.86
    webtest        1.34     1.30
    markdown       1.52     1.26
    core           2.33     1.89
    webtest        1.37     1.33
    markdown       1.53     1.28
    core           2.34     1.88
    webtest        1.37     1.33

That is about 16% on markdown, 19% on core, and 3% on webtest, which is dominated by actors and lookups rather than by evaluating nodes. A `sample` of the Markdown bench puts `Evaluator.eval` at 14.3% of all samples before and 11.5% after (about 29% and 23% of the working thread, the rest being the idle main thread in `__ulock_wait`).

The change: `eval`, `evalNode`, `evalTail`, `locate` and `matchPattern` take `*const ast.Node`. The arms of both switches capture `|*x|`. The `evalX` helpers (`evalBinaryOp`, `evalFuncCall`, `evalList`, `evalSituationTail` and the rest, plus `callBuiltin` and `flattenDottedName`) take `*const ast.Node.Payload`. Every loop over a slice of nodes iterates with `|*stmt|`, so nothing is copied on the way to `eval`. A boxed child (`op.left`, a `*Node`) is passed as it is, where it used to be dereferenced with `.*`. Callers in main.zig, gc.zig, memory_test.zig and wasm_api.zig pass `&node`. The patch is large (200 lines changed in eval.zig) because there are about 110 call sites, but it is mechanical and the compiler found every one.

Why the obvious reading was wrong: the expected cost was a 104-byte memcpy per call, and there is none on the entry path. The cost was a hidden copy created by the capture syntax, which looks free. With a pointer capture the compiler reads only the fields an arm uses.

The error-wrapping `eval` -> `evalNode` -> `locate` chain is not a cost. `locate` runs only in the `catch` branch, and with `evalNode` inlined the success path has no extra call.

Not done, seen in the hot prologue:

- ReleaseSafe's stack-protector load and compare sit in `eval`'s prologue and epilogue because the frame is large. A frame of 1760 bytes is still large; it is the sum of every arm's locals, since all arms are inlined into one function. Splitting the cold arms (actor definitions, try/catch, spawn) into non-inlined functions would shrink it further and improve stack depth for deep recursion. Untested.
- Other helpers still take payload structs from slices by value in places (`for (xs) |entry|` over `Value.MapEntry` and similar) where a pointer would do. Those are not on the per-node path.

Verification: `zig build test` and `zig build wasm` pass. The Temper suites report zero failures with the same case counts as the base: webtest 43, html 646, core 51, works 160, reading 190. The Markdown bench prints the same lines as the base apart from the numbers. pages_show was not run; nothing here touches actors or compaction.
