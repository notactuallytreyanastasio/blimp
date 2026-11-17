# The Compiler Was Throwing Bubbles Away

*November 16, 2026*

Blimp has two ways to run a program. `blimp` interprets it, and `blimp-compile` turns it into LLVM IR and links a native binary against a small C runtime. This chapter is about the place where the two disagreed most: what happens when a handler gives up.

A handler gives up with `bubble`. The bubble carries a reason back to whoever sent the message, and a `try ... catch` or an `orelse` around the send can handle it. If nothing handles it, the interpreter stops and tells you where it came from. Take this program:

```
actor V do
  state n: Int :: 0
  on :check(x: Int) do
    situation x do
      1 -> reply 10
      _ -> bubble :too_small
    end
  end
end
v = spawn V
r = v <- :check(0)
r + 1
```

The interpreter prints this and exits 1:

```
-- UNCAUGHT BUBBLE ───────────────────────────────

  A bubble reached the top of the program: :too_small

6|       _ -> bubble :too_small
                ^

  Hint: Handle it with `try ... catch` or `orelse`.
```

Before this chapter, the compiled version of the same file printed `1` and exited 0.

## Why it printed 1

We dumped the IR for a handler that bubbles and a handler that does `reply 0`, side by side, with `blimp-compile --dump-ir`:

```
define { i1, i64 } @V_handler_a(ptr %0) {
entry:
  ...
  ret { i1, i64 } { i1 true, i64 0 }
}

define { i1, i64 } @V_handler_b(ptr %0) {
entry:
  ...
  ret { i1, i64 } { i1 true, i64 0 }
}
```

The two bodies match instruction for instruction. The compiler evaluated the bubble's reason, dropped it and returned "matched, value 0". So `r` got 0, `r + 1` gave 1, and the program looked fine. An `orelse` had the same blind spot from the other side: `v <- :zero orelse 99` printed 99 when the handler had replied 0 on purpose, because the compiled `orelse` compared the reply against 0. Two neighbouring cases went wrong the same way. Integer division compiled to a bare LLVM `sdiv`, which is undefined behaviour on a zero divisor, and `10 / x` with `x = 0` came out as 1. A message with no handler replied 0.

The compiler had no tests of its own to catch any of this, since `zig build test` never compiles `codegen.zig`. So the first commit adds 22 fixtures in `test/compiled/`. Each pairs a `.blimp` file with an `.expected` file of output and exit status, and the interpreter wrote every runtime expectation. The runner makes one more check, that `blimp-compile --run` hands back the program's exit status, so it counts 23. Against the old compiler, 3 passed and 20 failed. The 3 that passed are `orelse` cases where falling back on a 0 happens to give the right answer.

## Where the reason goes now

Handlers already returned a pair, `{i1 matched, i64 value}`. We widened the flag to a status byte with five values: no match, ok, nil, bubble and fault. For a bubble or a fault, the value is a pointer to a record holding the reason and the report to print, with the source line it came from. The runtime keeps the status next to the reply in the message, `blimp_send` returns both, and the generated code checks it at every send. A bubble goes to the nearest `try` or `orelse` in the same function. With neither around, a handler passes it back to its own sender, and the top level prints the report and exits 1. A fault such as division by zero skips any `orelse` and goes to a `try`, which matches the interpreter.

The obvious design is a global "last error" that `bubble` writes and `catch` reads. The interpreter used to work that way, and commit 9950dcd fixed the bug it produced there: a bubble the program had already caught was what a later, unrelated failure printed, because the catch never cleared the slot. Compiled code would make it worse. While `blimp_send` waits for a reply it runs other actors' handlers, and any of them can overwrite the slot between a bubble and the check for it. A status inside the return value belongs to one send, and no other code can read it. We also ruled out `setjmp`/`longjmp`, because a jump out of a handler unwinds through the scheduler's frames and leaves the actor marked busy with its message never answered.

Compiled now, the program above prints the same UNCAUGHT BUBBLE report and exits 1. We compared the compiled program's stderr with the interpreter's using `cmp`, and they match byte for byte, colour codes included. Catching works too. This prints `:too_small`, where the old compiler refused the `try` with `Codegen error: error.UnsupportedNode`:

```
r = try do
  v <- :check(0)
catch err do
  err
end
r
```

## What it won't compile

A `def` in compiled Blimp returns a bare integer, so a bubble inside one has nowhere to go. The compiler now says so and stops, naming the construct and pointing at it:

```
-- CANNOT COMPILE ──────────────────────────────────────────

  `try` around a call to `half`: a bubble or a division by zero inside a def cannot reach this catch in compiled code.

4| r = try do
        ^

  Hint: Call the def outside the `try`, or run this file with the interpreter.

1 construct cannot be compiled.
```

The compiler also refuses `bubble` inside a dotted actor like `Marketplace.AccountHolder.Account`, which the interpreter restarts under its supervisor. Compiled actors have no supervisor to do that. `examples/marketplace.blimp` used to compile and print a heap address as its answer, and the compiler now stops it at line 41 with the actor and its supervisor named. Anything else codegen can't handle gets a report with the node and the line, where it used to print `Codegen error: error.UnsupportedNode` and nothing more.

## The harness we broke

Chapter 71 added a harness that runs every program in its corpus through both the interpreter and the compiler and records each disagreement in `known.json`. It recognised a compiler refusal by the string `error.UnsupportedNode`. Our second commit replaced that string with the new report, and the old harness then failed on 30 programs, none of them a regression. It filed every refusal under "failed some other way" and saved the report's first line, a row of box-drawing characters, as the error.

The third commit teaches the harness the new report and keeps the sentence under the rule. After re-recording, the 146 programs give 63 agreements against 56 on the branch before, and the number that run on both sides with different answers drops from 25 to 18. The entry for `test/case_anywhere_test.blimp`, recorded in chapter 74, is a bug this chapter didn't touch: a `case` whose branches aren't Ints fails LLVM verification with a PHI type mismatch.

## Still wrong

We ran each of these on this branch, and each one still disagrees with the interpreter:

- A def that divides by zero, called from a handler whose sender wraps the send in `try`. The interpreter catches it and prints `:division_by_zero`; the compiled program exits 1 with the report.
- `reply "hello"` reaches the sender as a number, `4364909596` on our run, because the compiler types every send as Int.
- `x = 0` then `x orelse 5` prints 5. The status byte fixed `orelse` on a send and nowhere else.
- The smallest Int divided by -1 still prints 1, where the interpreter wraps to `-9223372036854775808`.

`make check` doesn't run the compiled fixtures or the harness yet, because both need LLVM and the check script doesn't look for it. You can run the fixtures from `chunks/lang`:

```
zig build -Dllvm=/opt/homebrew/opt/llvm@22
sh test/compiled/run.sh
```

On this branch that prints `compiled fixtures: 23 passed, 0 failed`: the 22 fixtures and the `--run` check, which used to get 0 back whatever the program did.
