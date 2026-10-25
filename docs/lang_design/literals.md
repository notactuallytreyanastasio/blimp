# literals are built once by the parser; the saving is about 2%

The measured effect is small: the three benchmarks are 1 to 4% faster, which
is at the edge of this machine's run-to-run noise (10%), though B was ahead
in all nine pairs except core in round one:

```
bench             A        B
markdown       1.89     1.85
core           2.63     2.64
webtest        1.51     1.49
markdown       2.04     1.99
core           2.72     2.67
webtest        1.47     1.44
markdown       1.93     1.82
core           2.62     2.54
webtest        1.42     1.41
```

The brief put literal work inside the 42% attributed to Evaluator.eval. Most
of that is not literals. `evalNode` takes `node: ast.Node` by value, so every
evaluation of every node copies the whole tagged union before it switches on
it. I did not measure that copy; it is a suspect, not a finding. This
change removes the allocation, not the copy.

What changed

A string literal used to be classified at every evaluation: strip the quotes,
scan for `#{`, scan for a backslash, then allocate. The parser now does that
once. A plain string, an atom, a float and an integer carry `prebuilt:
?*const Value`; integers inside the interned range get the shared pointer
from `value.interned`, the rest are allocated in the parser's allocator. The
text of an escaped string is unescaped once.

An interpolated string used to run a fresh `Parser` over every `#{...}` at
every evaluation, with the nodes allocated in the heap. The parser now splits
the literal into `Interp.parts` (unescaped text, or an expression node) once.
If a `#{` is unbalanced or an expression does not parse, the node is marked
`bad` and evaluating it returns `UnsupportedOperation`, as before: a bad
literal that is never evaluated is still not an error.

A string pattern in a `case` compares against the prebuilt text instead of
unescaping on every match.

Dot access flattened `a.b.c` into a freshly allocated string and ran
`env.lookup` on it every time, including for `order.total`, which has never
been a bound name. The parser now flattens once and stores the name only when
every part starts with an upper-case letter. `actor` is the only thing that
binds a dotted name (eval.zig, the `def` for an actor, via `upper_identifier`
in the parser), so a lower-case chain skips the lookup altogether and goes
straight to the field. A node built by hand (`flat_checked == false`) takes
the old path.

Why the prebuilt Value is safe against compaction

`Copier.value` copies by value and memoizes by source address; it never frees
or relocates a source value, so a code-arena Value reached from a binding is
copied into the new heap like any other. Nothing keyed by address assumes the
source is in the old heap. The lifetime rule is simply "the Value is
allocated with the allocator that allocated its node". That is the code arena
in `run`, the REPL and `serve`. In the wasm `send` path the parser is given
`heap()`, so the AST and its literals die together at the next compaction,
which is also how the AST behaved before. The test in gc.zig parses literals
once, binds them, compacts, frees the old heap, and evaluates the same nodes
again, then compacts a second time.

What does not work, or was not done

The checker and codegen still read `StringLit.value`, the raw lexeme, so it
is kept. The LLVM build (`zig build` without `interp`) could not be tried
here: LLVM 20 is not installed. `zig build wasm` and `zig build test` pass.
`pages_show` was not run; nothing here touches actors or compaction
mechanics beyond the one new test.

The obvious further step, passing `*const Node` through `evalNode` instead of
a copy, is a separate change that touches every call of `eval`.
