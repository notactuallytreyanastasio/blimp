# Every Failing Test Said "Assertion Failed"

*November 16, 2026*

Here is a Blimp test whose only assertion compares 1 with 1:

```
actor LexerTests do
  test "tokenizes integers" do
    l = spawn Lexer
    assert_eq(1, 1)
  end
end
```

No actor called `Lexer` exists. Before this chapter, `blimp --test` reported it like this:

```
  FAIL LexerTests > tokenizes integers
    assertion failed

1 failed, 0 passed, 1 total
```

The assertion is fine. The spawn on the line above it failed, and the runner told you to go look at the one line in the test that was correct. Put `spawn Lexer` at the top level of a file instead, or inside a handler, and a plain `blimp` run prints a TEMPLATE NOT FOUND report with the line and a caret, then exits 1. The evaluator built that same report inside the test too. The test runner caught the error with a bare `catch`, dropped the report, and wrote the same summary line for every test that stopped.

## How many kinds of failure looked like this

We wrote a test for each kind of runtime error we could think of and ran them on the old binary. A send to a handler that does not exist, `1 + "a"`, `1 / 0`, a call to a function that does not exist, an undefined variable, and a `bubble` that nothing caught all came out as `assertion failed`. Inside a `property` the line was `property falsified`, which told you just as little.

On this branch the line under FAIL is the evaluator's own report, indented to sit under the test name:

```
  FAIL KindTests > send to missing handler
    -- NO MATCHING HANDLER ---------------------------

      I tried to send :pong to this actor, but it doesn't know how to handle it.

    9|     a <- :pong
             ^

      Hint: Actor `A` has no handler for `:pong`.
```

A bubble that escapes a test says it reached "the top of the test" rather than "the top of the program", because the error stops the test while the rest of the file keeps running. Real assertions keep their one line and now say what they compared. The builtins were already recording that for the in-browser runner:

```
  FAIL SpawnTests > an assertion still says what it compared
    assertion failed: expected 5, got 4
```

## The stale error

You might expect the fix to be one line: print `last_error`, the report the evaluator keeps, under each FAIL. That version gives wrong answers. Nothing cleared `last_error` between tests, and the function that attaches a location to an error keeps the first located error it finds. So once one test had failed with a report, a later test would show that report as its own.

We checked by building this branch with the reset line removed. In the fixture, the third test uses an undefined variable called `missing` and the fifth sends a message whose handler bubbles `:kaboom`. The fifth test reported:

```
  FAIL SpawnTests > a bubble says its reason, not an earlier test's error
    -- UNDEFINED VARIABLE ----------------------------

      I can't find a variable called `missing`.

    30|     assert_eq(missing, 1)
```

That FAIL quotes a line from a different test. The fix is `clearTestFailure`, which clears the last error, the bubble's reason and position, and the assertion detail before each test body and before each of a property's hundred runs. We hit this kind of bug in chapter 75 as well: a global "last error" slot outlives whatever set it, and every reader then has to know when to stop trusting it.

## A fix that exposed the next bug

The runner evaluates an actor's state defaults again before every test, so each test gets fresh actors. A default that failed was skipped with `catch continue`. With the first commit in place, the runner printed the real error for that, and it was misleading:

```
actor LexerTests do
  state lexer: Any :: spawn Lexer
  test "uses lexer from state" do
    assert_eq(lexer, 1)
  end
end
```

```
  FAIL LexerTests > uses lexer from state
    -- UNDEFINED VARIABLE ----------------------------

      I can't find a variable called `lexer`.
```

The variable is undefined because its default failed, and that default is the line you need to see. The old runner said `assertion failed`, which was wrong in a different way. The second commit fails the test with the default's own error and skips the body:

```
  FAIL LexerTests > uses lexer from state
    -- TEMPLATE NOT FOUND ----------------------------

      No actor template called `Lexer` is defined.

    2|   state lexer: Any :: spawn Lexer
                               ^
```

The runner had two copies of the state loop, one for tests and one for properties. They are now a single function, `evalTestState`, which returns the first error it hits.

## One slot we missed

Clearing between tests still left a stale slot inside a single test. A `try` that caught a failed assertion cleared the last error but not the assertion detail, and the runner prefers that detail whenever a test stops with a `TypeError`. `1 + "a"` stops with a `TypeError` too. So on the second commit this test:

```
r = try do
  assert_eq(1, 2)
catch err do
  err
end
x = 1 + "a"
```

was reported as `assertion failed: expected 2, got 1`. The same happened after a handler run by `schedule()` failed an assertion, and a `case` guard like `n when n + "a"` that failed left its TYPE MISMATCH behind, which a later `bubble` in the same test then reported as its own.

The third commit adds `dropHandledError` and calls it at every place that handles an error and carries on: `try`, `orelse`, the three guard evaluations and the two catches in the mailbox loop. All three tests now name what stopped them.

Having the runner look at the error itself can't work: a failed assertion and `1 + "a"` both return `error.TypeError` and a Zig error carries no payload. Giving assertions their own error would change what `catch e` binds, which is a language change. Clearing the report where the error is handled ties the report's lifetime to the error's.

## Pinning it down

`test/runner/failures.blimp` contains fifteen tests that fail on purpose, covering spawns, an undefined variable, bubbles, two properties, a state default and seven handled-then-failed orders, and `failures.expected` holds what the runner should print for them. A new suite in `make check` runs the file, requires a non-zero exit, strips the colour codes and the timing line, and diffs the rest. Run with the old binary, that diff changes 142 lines, and every FAIL block in it says `assertion failed` or `property falsified`. `make check` passes on this branch with 14 suites, one more than before.

## Still wrong

We ran each of these on this branch.

A failure that a mailbox handler or a guard swallows is still swallowed. The third commit stops it from being blamed for the next failure, but nothing reports it either. A test that sends `s <-- :put` to a handler doing `assert_eq(1, 2)`, runs `schedule()`, then evaluates a `case` whose guard `n + "a"` fails, still passes. The only trace is the builtin's own `Assertion failed` block on stderr.

The browser runner in `wasm_api.zig` is unchanged. From Node, `runTests` on the wasm build with the `spawn Lexer` test returns `{"ok":false,"detail":"assertion failed"}`. The `blimp_test(code)` builtin still skips failing state defaults and reports only the test's name.

A builtin that fails without a message stays vague. `length(5)` in a test prints "TypeError while evaluating this." A plain run never gets there: the static checker stops it first, and the checker skips test bodies.

The assertion builtins also still print their own `Assertion failed: values not equal` block among the progress dots, so a failed `assert_eq` is now reported twice.
