# 134 Zig tests that never ran, and a make check that can go red

*November 16, 2026*

This chapter comes before the next batch of Blimp work, starting with a harness that runs the interpreter and the compiler side by side. It gives `chunks/lang` one command that says whether the tree is healthy. That took seven commits, and most of them fixed the tests rather than the language.

## The toolchain first

`.tool-versions` named zig 0.15.2, but commits `50ac85e` and `8b1accf` ported the source to 0.16 in September. The first commit of this chapter records 0.15.2 failing to link its own build runner. Homebrew's 0.17.1 fails too:

```
$ /opt/homebrew/bin/zig build interp
build.zig:29:7: error: no field named 'ReleaseSafe' in enum 'lang.Optimize'
```

The pin says 0.16.0 now, so mise resolves `zig` inside `chunks/lang` to the one compiler that works:

```
$ zig version
0.16.0
```

## 196 failures, and most of them meant nothing

On `origin/main`, `blimp test lib` exits 1 after 196 failures. An excerpt of its output today:

```
bootstrap_test.blimp
16 failed, 0 passed, 16 total
codegen_test.blimp
23 failed, 0 passed, 23 total
...
lexer_test.blimp
36 failed, 0 passed, 36 total
...
safe_string_test.blimp
34 failed, 0 passed, 34 total
```

`lib/lexer_test.blimp` tests the `Lexer` actor in `lib/lexer.blimp`, but Blimp has no import and the runner parses each test file alone, so every `spawn Lexer` ran against nothing. A test that spawns an actor nobody defined reports a plain assertion failure:

```
  FAIL LexerTests > tokenizes integers
    assertion failed
```

It never says that `Lexer` doesn't exist, so a missing module reads as 36 broken lexer tests, and this chapter leaves that message as it is.

The fix is a header line. A test file names the files it tests:

```blimp
# Comprehensive lexer tests
# prelude: lexer.blimp
```

and `blimp test lib` and `blimp FILE --test` both load each named file before the tests, through the path `--preload` already used. The runner parses each prelude on its own, so an error's line number points into the file it came from. A prelude that isn't there stops the file and fails the run. You can try it with a scratch file:

```
$ printf '# prelude: nope.blimp\n\nactor T do\n  test "x" do assert(true) end\nend\n' > missing_prelude_test.blimp
$ blimp missing_prelude_test.blimp --test
prelude ./nope.blimp: error.FileNotFound
$ echo $?
1
```

With preludes, 183 of the 196 failures went away.

## The 13 that were real

Twelve of the remaining 13 were in `safe_string`. Three of the `safe_sql` tests failed because `safe_sql` had not worked since the file was added in March. It handed its SQL builder to the HTML walker, whose accumulator has a different type:

```
-- TYPE MISMATCH ─────────────────────────────────

  I can't use `acc` with ActorRef on the left and SafeHtmlAccumulator on the right.

368|   build_safe_html(builder, parts, 0)
```

Loosening that parameter to `Any` would have silenced the checker and broken SQL, because the HTML walker calls `to_string` on every unsafe value. A parameter of `42` would go to the database as `"42"`. `safe_sql` got its own walker instead, and a test that checks the parameter keeps its type:

```
%{__safe_sql__: true, query: "SELECT * FROM t WHERE id = $1", params: [42]}
```

The eight HTML context tests read a key called `"state"`. The code writes `st`, because `state` is a Blimp keyword and `%{state: :pcdata}` doesn't parse.

The last two failures were tests that only passed one way of running them. The `argv` test hard-coded `"--test"` as the second argument, which is false under `blimp test lib`. The `safe_sql` property asserted that the random string `s` never appears in the query. That fails on correct code whenever `s` is a single character like `E` or `=`, which are already in `SELECT * FROM t WHERE x = $1`. The property passed under `--test` only because `random` starts from a fixed seed, and in the longer `blimp test lib` run the sequence reaches one of those characters. It now checks the whole query string and the parameter list.

## Tree-sitter had three problems stacked

`tree-sitter test` had not passed since March. The CLI that `package.json` pins can't load the generated parser:

```
$ cd tree-sitter-blimp
$ npx --yes -p tree-sitter-cli@0.24.7 tree-sitter test
Incompatible language version 15. Expected minimum 13, maximum 14
```

With 0.25.10 it loads, and two spawn corpus tests fail because the grammar started wrapping the actor name in `spawn_target` and the expected trees didn't follow. With those updated, the highlight query for handler parameters turned out to be a pattern that can never match. All three are fixed, and the run is 63/63. The pin in `package.json` is still `^0.24.0`; `make check` fetches 0.25.10 by version instead.

## make check, and the tests it missed

`make test` on `origin/main` built a static library and ran nothing:

```
$ make test
zig build-lib -Mblimp=src/lib.zig -target aarch64-macos-none -lSystem
$ echo $?
0
```

The Makefile now delegates to `zig build`, and `make check` runs `scripts/check.sh`: the Zig unit tests, both Blimp suites, the examples that have tests, the node tests against the wasm just built, the python tests and tree-sitter. Every suite runs even after one fails, and a missing tool counts as a failure. One suite runs `examples/test_failing.blimp` and passes only if that exits 1, since a runner that can't fail prints the same green as a healthy one.

The commit that added `make check` said it ran every suite, and the next commit found 134 tests it had never run. Four files, `token_test.zig`, `parser_test.zig`, `checker_test.zig` and `errors_test.zig`, hold 134 tests, and nothing imports them, so `zig build test` never compiled them. You can see it on `origin/main` by appending a test that must fail:

```
$ printf '\ntest "canary" { try @import("std").testing.expect(false); }\n' >> src/token_test.zig
$ zig build test --summary all
Build Summary: 5/5 steps succeeded; 891/899 tests passed (8 skipped)
```

Imported from `lib.zig`, two of the files didn't compile against 0.16, and once they did, one of the 134 tests failed because it expected a string literal's `value` without quotes, where the lexer has kept them since the test was written. The test now expects the quotes. `zig build test` reports 1030/1038, with 8 skipped for live Postgres.

`check.sh` also checks that every `src/*_test.zig` is imported, by grepping `lib.zig` for the import line. Comment the line out with `//` and the grep still matches, so the guard passes. We tried it, and the guard printed nothing until we deleted the line. The last commit in this chapter tightens the pattern so that only indentation and `_ = ` may come before `@import`, and the guard now fails on the commented line and names the file.

## Running it

From `chunks/lang`, on a fresh cache, `make check` took 1m37s here and ended:

```
-- tree-sitter test: ok

all suites passed
```

Still outside it: nine `examples/*.blimp` that fail when run as programs, and the Elixir comparison tool, which the next chapter picks up. The tree-sitter grammar also can't parse a typed `def` yet; `def f(n: Int) -> Int do n end` comes back with two `ERROR` nodes.
