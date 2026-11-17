# The Compiler Knew It Was a Bool

*November 16, 2026*

Compiled Blimp printed `1` for `4 == 4`, and the type was known the whole time. Every value in `codegen.zig` travels with a static tag (`ValTag`: int, float, boolean, string, atom, nil, actor_ref, tagged_val), and the printer already prints a `.boolean` as `true` or `false`. The comparison code produced the right i64 and then stamped it `.int`. The tag was right when the value was made and wrong by the time anything printed it.

Chapter 71's harness has been listing the results since it was written. Most of what it still called a divergence came from the same move, a correct value with its tag overwritten by Int, repeated in seven places: a comparison, `&&`, a reply arriving from a send, a case's result, a def's return value, a handler parameter and a state field. This branch removes each one. On chapter 82, then on this branch:

```
agree          71  ->  93
compile-error  10  ->   3
diverge        17  ->   1
flaky           1  ->   0
```

The one divergence left is `protocol_plain_run`, which exists to record that `blimp FILE` prints nothing where a binary prints its last value.

## Comparisons, and a division that should not run

Retagging the result of `==` as `.boolean` fixed `arith_compare_eq` and four more corpus programs. Doing the same for `&&` and `||` would have left a second bug in place. They compiled to `LLVMBuildAnd` and `LLVMBuildOr` of both sides, so both sides always ran. On chapter 82:

```
puts(false && 1 / 0 == 0)
```

stops with DIVISION BY ZERO and exits 1. The interpreter prints `false`, because it never looks at the right side. `&&` and `||` are now a branch and a phi:

```
  %lhs_true = icmp ne i64 %x1, 0
  br i1 %lhs_true, label %logic_rhs, label %logic_merge
```

Both sides must now be Bools. The interpreter decides by truthiness, so an Int 0 counts as true there, while an i64 compared against 0 would say false. Compiled code now refuses an Int operand and names the operand.

## The send

A reply already crossed `blimp_send` intact, as the i64 half of a `{status, value}` pair. On the receiving side it was tagged Int, so the printer misread it:

```
reply :pong       interpreter :pong    chapter 82  1
reply name        interpreter bob      chapter 82  4375953090
```

The second number is the String's address. The obvious fix is to box every value that crosses a send. We didn't, because whatever receives a send result (arithmetic, a comparison, a state store, a def argument) works on raw i64s, and a box would need an unbox and a run-time type check at every one of them. Compiled code has no run-time types to check. It also doesn't need them here. A send is synchronous, and every handler is in the one file being compiled, so the reply's type is known statically: the union of what the handlers for that message reply. Each handler records a bit per tag as it compiles, and the send takes the union. When the union isn't a single tag, the compiler refuses the send and names it:

```
  Handlers of :q reply an Int and an Atom; a compiled send takes one type of reply.

14| a <- :q(1)
    ^
```

A handler that replies on some paths and not others is accepted only on the left of `orelse`, which reads the status. A send compiled before the handler it reaches is assumed to get an Int back. Once everything is compiled, `checkSends` checks that assumption and refuses the send if the handler disagrees.

Handler parameters had the same problem in the other direction: they were bound as Int whatever their annotation said. They now take their annotation's type. A parameter typed `Any`, `Map` or a record type like `Item` is refused where it is read. So `examples/pipes.blimp` and four other programs, which were refused before, are now refused with "Parameter `item` of :push is typed Item".

## The rest of the list

Defs, case and `orelse` get the same treatment. A def call takes the type of the def's last expression, so `def name(x: Int) do "bob" end` stops failing LLVM verification with `ret ptr` in an i64 function. A case is `nil` when no branch matches, where it used to be 0, and the branches keep their type, so a case returning atoms stops producing a phi that mixes i32 and i64. In `orelse` the tag decides what counts as nil: `x = 0; x orelse 5` printed 5 because the old test compared the i64 with 0, and it now prints 0.

The smallest Int divided by -1 printed `1`. In LLVM, `sdiv` of that pair is undefined, and O3 is free to make anything of it. A check that faults on the pair would be a third answer, since the interpreter wraps and doesn't fault. So a divisor of -1 becomes `0 - a` with no `nsw` flag, which gives `-9223372036854775808` on both sides.

Floats printed with `%g`, so `0.1 + 0.2` came out as `0.3`. The runtime's new `format_float` tries `%.{p-1}e` for p from 1 to 17 and keeps the first result that `strtod` reads back as the same double, then places the decimal point by hand. That reproduces Zig's `{d}`. We ran it against the interpreter on `1e300`, `5e-324`, `2.2250738585072014e-308`, `1.7976931348623157e308`, `1e22`, `1e23` and the fixture's nine values, and `cmp` found no difference.

String escapes go through the parser's own unescape function now, so `puts("a\nb")` prints two lines. An interpolated string is refused instead of being printed as its literal `#{n}`. An actor prints as `ref<C:1>` where it used to print as its slot number.

## A fixture that was wrong twice

One test took three commits. The first said the checker refuses `!` on an Int before anything runs, and that `blimp-compile` skips the checker. Both claims were false: the compiler runs the same checker, and on chapter 79, where this work was written, the checker let `x = 0; !x` through, by the last commit's account. A later commit corrected the claims. Then the chapter was moved onto chapter 80, whose checker does refuse that program on both sides:

```
Type error at line 2, col 1: logical not expects Bool, got Int
```

That left the fixture testing the checker and no longer the compiler. The last commit hides the type behind `def dyn(v: Any) -> Any do v end`, and then the interpreter prints `false` and the compiler refuses `!x` at the operand. The interpreter and the checker still disagree about `!` on an Int, the same disagreement as `assert(42 && true)` in `lib/operator_test.blimp`, and this branch leaves it open.

## Still wrong

Each of these was run on this branch:

- `y = case 5 do 1 -> 10 end` then `y + 1`. `y` is boxed (Int or nil), and `+` on it fails LLVM verification with `add ptr %y4, i64 1`. Chapter 82 printed `1`.
- A recursive `def even` whose case mixes `true` with its own call. The call is still assumed Int while the def compiles, so the case boxes, and the refusal says `even` "returns a list, map or fn value". The interpreter prints `true`.
- `a.c` on an Atom field prints `0` and exits 0, while the interpreter exits 1 with a TypeError.
- `==` on two Strings still compares pointers. We couldn't produce a disagreement, because every compiled String is a literal and LLVM merges equal literals: `"#" == "\#"` prints `true`.
- Lists of atoms, floats or strings still fail verification.

`sh test/compiled/run.sh` passes 54 fixtures (36 on chapter 82), and `make check` passes on both builds.
