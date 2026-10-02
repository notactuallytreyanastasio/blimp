# Test Framework: First-Class TDD for Blimp

> The runner is already the runtime with a flag flipped, and a test is just a handler shape. Everything missing from today's setup is ergonomics, not design.

## Premise

Blimp already runs tests. You can write `test "name" do ... end` inside an actor, call `assert_eq` on anything, and `blimp test dir/` discovers `*_test.blimp` files and runs them. Exit codes are correct, output is colored, summaries print.

What's missing is everything that makes TDD feel good as a feedback loop: source lines on failure, structural diffs, watch mode, focused reruns, setup hooks, progress reporting, and a few shaped-for-actors assertions that the current suite doesn't have.

This doc is about building the missing pieces without adding a framework tax.

## Design principles

Tests are actors. We don't invent a parallel object model. A test suite is an actor whose state fields are fixtures and whose `test` blocks are handler-shaped mini-programs. If you know Blimp, you already know how to write tests.

Fresh state per test. The runner re-evaluates state defaults for every `test` block, which is already true. Setup hooks run on top of that fresh state, not around it.

Feedback loop speed over expressiveness. A framework with 40 matchers that takes 4 seconds to re-run loses to one with 6 matchers that re-runs in 200ms on save. Watch mode is first class, not an afterthought.

One entry point. `blimp test` does everything. No separate runner binary, no config file required for the common case.

Functional core, imperative shell, in the tests too. Pure logic tests should dominate. Tests that require side effects (sockets, views, wall clock) are a minority and live behind explicit setup.

## State of today

| Capability | Status | Notes |
|---|---|---|
| `blimp file.blimp --test` | YES | Runs `test` blocks in actors |
| `blimp test dir/` | YES | Discovers `*_test.blimp` recursively |
| `test "name" do ... end` | YES | Inside actor body only |
| Fresh state per test | YES | Re-evaluates state defaults each test |
| Assertions | PARTIAL | `assert`, `assert_eq`, `assert_ne`, `refute` |
| Property testing | YES | `property "name" do given x: gen... end`, 100 iterations |
| Exit codes | YES | Non-zero on failure |
| Colored output | YES | Green dot / red F |
| Summary | YES | `N passed`, `M failed, N passed, total` |
| Source line on failure | NO | Generic "assertion failed" only |
| Structural diff | NO | Prints two blobs, doesn't show delta |
| Per-test timing | NO | Only total elapsed |
| Watch mode | NO |  |
| Name filter | NO |  |
| `skip` / `only` | NO |  |
| `before_each` / `after_each` | NO | State default is the only fixture mechanism |
| `describe` / context blocks | NO | Actors are the only grouping |
| JSON / TAP reporter | NO | Human-readable only |
| Assertion helpers for actor semantics | NO | No `assert_bubble`, `assert_receive` |

## What first-class looks like

### Runner CLI

```
blimp test [path]                   # discover and run
blimp test --watch                  # rerun on file change
blimp test --filter "rent"          # substring match on test name
blimp test --seed 42                # deterministic shuffle
blimp test --timings                # print ms per test
blimp test --reporter json          # machine-readable output
blimp test --reporter tap           # TAP for CI tools
blimp test --progress               # curriculum view (tutorial use)
blimp test --fail-fast              # stop at first failure
```

No config file needed. All defaults sensible. `blimp test` with no args runs everything in the current directory.

### Syntax additions

**Skip and focus.** Prefix directives on `test`:

```
skip test "flaky for now" do
  ...
end

only test "this one I'm iterating on" do
  ...
end
```

When any `only` exists in a run, only those tests execute. Everything else is reported as filtered, not skipped, so the summary is honest.

**Setup hooks.** Optional, for cases where the state-default fixture isn't enough:

```
actor BikeTests do
  state bike: Bike :: spawn Bike

  before_each do
    bike <- :reset
  end

  after_each do
    bike <- :disconnect
  end

  test "..." do
    ...
  end
end
```

`before_each` runs on the fresh fixture. `after_each` runs even if the test failed. Neither is required; most suites won't need them.

**Grouping.** Optional nested groups for readability:

```
actor BikeTests do
  group "when available" do
    test "rent succeeds" do ... end
    test "status is :available" do ... end
  end

  group "when rented" do
    before_each do bike <- :rent end
    test "rent fails" do ... end
    test "return works" do ... end
  end
end
```

Groups nest. Each group can have its own `before_each` which composes with outer hooks. If you don't want groups, you don't write them.

### Assertions shaped for actors

Beyond `assert`, `assert_eq`, `assert_ne`, `refute`, add:

```
assert_match(value, pattern)        # pattern-match assertion
assert_eq_struct(a, b)              # structural diff on mismatch
assert_bubble(expr, :signal)        # expression bubbled this signal
assert_restart(actor_ref)           # actor was restarted since call
assert_state(actor_ref, field, value)  # field matches value
refute_match(value, pattern)
```

`assert_match` is the one I'm most excited about. Pattern matching is already how Blimp expresses expectations in handlers; tests should feel the same:

```
test "status handler returns a tuple" do
  assert_match(bike <- :info, {:ok, _id, :available})
end
```

`assert_bubble` makes supervision tests ergonomic:

```
test "overdraft bubbles :insufficient_funds" do
  assert_bubble(account <- :overdraft, :insufficient_funds)
end
```

`assert_state` sidesteps the "expose a getter just so I can test" anti-pattern by reading the actor's state directly through the runtime.

### Failure reporting

Every failure prints:

- Source location (`file.blimp:42`)
- Test name and containing actor
- Assertion that failed, with a structural diff for composite values

```
  FAIL  BikeTests > renting flips status
    bike_test.blimp:17
    assert_eq(bike <- :status, :rented)

    expected: :rented
    actual:   :available
```

For maps and lists, show the delta, not two blobs:

```
    expected: %{id: "b-001", status: :rented, gps: {40.7, -73.9}}
    actual:   %{id: "b-001", status: :available, gps: {40.7, -73.9}}

    diff:
      status: :available -> :rented
```

### Watch mode

`blimp test --watch` watches the test file and the files it imports, reruns on save. Clear screen, print failures first, dot-style summary at the bottom.

Implementation: fsevents on macOS, inotify on Linux, small Zig wrapper. Debounce 150ms. When a file changes, re-run only affected files, fall back to full run if the dependency graph is unclear.

If `--watch` plus `--filter` is the common iteration pattern, that's fine. The point is the inner loop drops to single-digit seconds.

### Reporters

Three reporters:

- human (default): the thing you see now, upgraded with source lines and structural diffs
- json: `{tests: [{name, status, ms, error?, file, line}], summary: {pass, fail, skip, total, elapsed_ms}}`
- tap: Test Anything Protocol for CI tools

No plugin architecture. These three are baked in. If someone wants a custom reporter they parse the JSON.

### Curriculum mode

`blimp test --progress` is built for the tutorial but useful for any directory of graded exercises. Looks for a `curriculum.toml`:

```toml
[[chapter]]
title = "Ch 1: Your first actor"
path  = "exercises/ch01_first_actor"

[[chapter]]
title = "Ch 2: State, become, guards"
path  = "exercises/ch02_state"
```

Prints:

```
Ch 1: Your first actor     [##########]  4/4   (2.3s)
Ch 2: State, become        [#####-----]  2/5   (1.1s)
Ch 3: Actors talking       [----------]  0/5   (not started)

Total: 6/14   (3.4s)
```

This is one of those features that sounds niche but pays for itself the first time you're mid-tutorial and want to see where you are.

## MVP ranking

What to build first, ranked by tutorial impact and cost.

**Must-have before writing tutorial chapters:**

1. Source line on failure
2. Structural diff for maps and lists
3. `--watch` mode
4. `--filter` by test name
5. Per-test timing on `--timings`
6. `skip` / `only` directives

These unblock real TDD. Without source lines, a failing test is a treasure hunt. Without watch mode, the inner loop is typing `blimp test ...` over and over.

**Worth having, not blocking:**

7. `before_each` / `after_each` / `group`
8. `assert_match`, `assert_bubble`, `assert_state`
9. JSON reporter
10. `--progress` curriculum mode
11. `--fail-fast`

These improve the ergonomics past the tutorial's immediate needs.

**Future, explicitly not MVP:**

12. TAP reporter
13. Random ordering with seed
14. Parallel execution
15. Plugin architecture for reporters
16. Shrinking for property-based tests
17. Snapshot testing for views

Parallel execution is tempting because actors are isolated, but runtime coordination isn't free and most suites run in under a second anyway. Shelve until someone has a suite that takes long enough to matter.

## Implementation notes

- Most of this lives in `chunks/lang/src/eval.zig` (runner) and `chunks/lang/src/builtins.zig` (assertions)
- Source locations: AST nodes need to carry source spans through to assertion failure reporting. Check if they already do; most parsers track this but don't always thread it
- Structural diff is a new module, `src/diff.zig`, small and pure
- Watch mode is a new `src/watch.zig` wrapping the platform file-watching syscalls
- Curriculum mode reads TOML, probably with a tiny hand-rolled parser since the schema is narrow
- JSON reporter uses whatever JSON encoder the runtime already has

The whole MVP is maybe 600-900 lines of Zig, spread across the additions and wires. Nothing in here is architecturally interesting. It's mostly careful plumbing.

## Open questions

1. **`test` outside an actor?** Today it must be inside. Letting it live at top level would make quick one-off test scripts easier, but it breaks the "tests are actors, fixtures are state" model. Leaning: keep inside-actor only.

2. **How aggressive is `before_each` with groups?** If nested groups each have a `before_each`, they all run outer-to-inner. This matches every framework that does it well. No surprises.

3. **Property shrinking.** Current property tests run 100 iterations but don't shrink counter-examples. Shrinking is a real win when you have one, but implementing a general shrinker is its own project. Mark as future.

4. **`--canvas` integration.** Could the runner dump an animated tree for a failed test showing the actor mesh at the moment of failure? Probably yes, probably worth doing once the core is solid. Not MVP.

5. **Fixtures that aren't actors.** What if you want a fixture that's a plain value, not an actor? Today `state x: Int :: 42` works fine. So this isn't actually an open question, I'm just flagging that the fixture mechanism already generalizes.

## What this buys us

The tutorial becomes possible. Right now I can write a test for a bike, run it, see it fail, fix it, see it pass. But:

- I don't know what line the assertion failed on
- A struct mismatch prints two giant blobs
- I'm retyping `blimp test exercises/ch02_state/01_rental.blimp --test` every save
- I can't focus on one failing test while 30 others are still red
- Reporting progress across a curriculum requires my own bash script

With the MVP, all of that drops away. The tutorial reader sees:

```
$ blimp test --watch --progress

Ch 1: Your first actor     [##########]  4/4   (0.3s)
Ch 2: State, become        [##--------]  1/5   (0.2s)

  FAIL  BikeTests > renting flips status
    exercises/ch02_state/01_rental.blimp:17
    expected: :rented
    actual:   :available
```

They save the file, the screen updates in under a second, and they keep going.
