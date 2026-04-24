---
description: Build and test Elixir project with full quality checks
allowed-tools: Bash
argument-hint: [test pattern or path]
---

# Build and Test

Run the full quality cycle for the Elixir project.

## Instructions

1. Find the nearest mix.exs (check cwd, then chunks/, etc.)

2. Run the full quality cycle in order. Stop at the first failure:
   ```bash
   cd <project_dir>
   mix compile --warnings-as-errors
   mix test $ARGUMENTS
   mix credo --strict
   ```

3. If compilation fails with warnings, list every warning and fix them all.

4. If tests fail, analyze the failures:
   - Which test failed and in which file
   - What it was testing
   - The actual vs expected output
   - Fix the code (not the test, unless the test is wrong)

5. If credo fails, fix the issues.

6. Report the final status clearly:
   - Compile: pass/fail (N warnings)
   - Tests: N passed, N failed
   - Credo: pass/fail

## TDD Reminder

If you are WRITING code (not just running checks), follow the TDD loop:
1. Write the failing test FIRST
2. Run `mix test` to see it fail (Red)
3. Write the minimum implementation to pass (Green)
4. Refactor if needed, tests still pass
5. Run `mix compile --warnings-as-errors` to check for warnings

$ARGUMENTS
