#!/usr/bin/env bash
# Every test suite in chunks/lang, against an interpreter and a blimp.wasm
# built from this tree. Exits 0 only if all of them pass; otherwise it names
# each suite that failed and exits 1.
#
#   make check                   (or scripts/check.sh from anywhere)
#   ZIG=/path/to/zig make check  (default: `zig`, which mise resolves from
#                                 .tool-versions to 0.16.0 inside chunks/lang)
#   LLVM=/opt/homebrew/opt/llvm@22 make check
#                                (the LLVM prefix blimp-compile links; passed
#                                 to zig build as -Dllvm. Unset, build.zig
#                                 looks for one, see findLlvm, and the build
#                                 prints which it used)
#
# Needs: zig 0.16.0, an LLVM with libLLVM, node, python3, npx (tree-sitter-cli
# is fetched by version). A missing tool is a failed suite, not a skipped one:
# with no LLVM the interpreter suites still run and pass, and the compiler's
# three suites fail by name.
set -u
cd "$(dirname "$0")/.."

ZIG=${ZIG:-zig}
LLVM=${LLVM:-}
TREE_SITTER=${TREE_SITTER:-npx --yes -p tree-sitter-cli@0.25.10 tree-sitter}
BLIMP=./zig-out/bin/blimp
COMPILER_BUILT=0
failed=()

suite() {
    local name=$1
    shift
    printf '\n== %s\n' "$name"
    if "$@"; then
        printf -- '-- %s: ok\n' "$name"
    else
        printf -- '-- %s: FAILED\n' "$name"
        failed+=("$name")
    fi
}

# Without a build nothing below means anything, so this one stops the run.
printf '== build (%s %s)\n' "$ZIG" "$("$ZIG" version 2>&1)"
if ! "$ZIG" build interp || ! "$ZIG" build wasm; then
    echo "-- build: FAILED; no suite was run"
    exit 1
fi

examples_with_tests() {
    local f rc=0
    for f in examples/tetris.blimp examples/test_example.blimp examples/web_push.blimp; do
        echo "$f"
        "$BLIMP" "$f" --test || rc=1
    done
    return $rc
}

# The runner's own failure path: examples/test_failing.blimp fails two tests
# on purpose. If this passes, a red suite above could be printing green.
runner_reports_failure() {
    if "$BLIMP" examples/test_failing.blimp --test; then
        echo "examples/test_failing.blimp --test exited 0; the runner cannot fail"
        return 1
    fi
    return 0
}

# Every failure in a test body used to read "assertion failed", whatever it
# was: a spawn of an actor nobody defined looked like a wrong assertion. The
# runner prints the located error now; this compares it, colours and the
# timing line removed, against what the fixture expects.
runner_names_the_failure() {
    local out esc
    esc=$(printf '\033')
    if out=$("$BLIMP" test/runner/failures.blimp --test 2>&1); then
        echo "test/runner/failures.blimp --test exited 0; every test in it fails"
        return 1
    fi
    printf '%s\n' "$out" | sed "s/${esc}\[[0-9;]*m//g" | grep -v '^Finished in' |
        diff -u test/runner/failures.expected -
}

# Was a segfault (0xaaaaaaaaaaaaaaaa in evalMessageSend); it prints 1 now.
regression_spawn_in_send_arg() {
    local out
    out=$("$BLIMP" test/regression_spawn_in_send_arg.blimp) || return 1
    [ "$out" = "1" ] || { echo "expected 1, got: $out"; return 1; }
}

# A *_test.zig nothing imports compiles to nothing and fails nothing: four of
# them (134 tests) sat outside `zig build test` from March to November.
zig_test_files_imported() {
    local f rc=0
    for f in src/*_test.zig; do
        # Nothing but indentation and `_ = ` may come before the import: a
        # plain grep for the import's text is satisfied by the line
        # commented out, which is the usual way a test file stops running.
        grep -Eq "^[[:space:]]*(_[[:space:]]*=[[:space:]]*)?@import\\(\"$(basename "$f")\"\\)" src/lib.zig || {
            echo "$f is not imported by src/lib.zig, so zig build test never runs it"
            rc=1
        }
    done
    return $rc
}

# blimp-compile links LLVM, so unlike the interpreter it can fail to build on
# a machine that is otherwise fine. That fails three suites, not the run: the
# interpreter suites below do not need it.
build_compiler() {
    if "$ZIG" build ${LLVM:+"-Dllvm=$LLVM"}; then
        COMPILER_BUILT=1
        return 0
    fi
    echo "blimp-compile did not build; the error above says why. To choose an LLVM:"
    echo "  LLVM=/opt/homebrew/opt/llvm@22 make check"
    return 1
}

# A failed zig build leaves the last good zig-out/bin/blimp-compile in place,
# so running these after one would test an old compiler and could pass.
compiler_suite() {
    if [ "$COMPILER_BUILT" -ne 1 ]; then
        echo "not run: blimp-compile did not build in this run"
        return 1
    fi
    "$@"
}

suite "every src/*_test.zig is imported" zig_test_files_imported
suite "zig build test" "$ZIG" build test --summary all
suite "blimp test test" "$BLIMP" test test
suite "blimp test lib" "$BLIMP" test lib
suite "examples --test" examples_with_tests
suite "examples run as programs" env BLIMP="$BLIMP" scripts/run_examples.sh
suite "runner reports failure" runner_reports_failure
suite "runner names the failure" runner_names_the_failure
suite "regression_spawn_in_send_arg" regression_spawn_in_send_arg
suite "node web/test" env BLIMP_WASM="$PWD/zig-out/web/blimp.wasm" node --test web/test/
suite "python scripts" sh -c 'cd scripts && python3 -B -m unittest trace_receipt_test.py'
# The CLI caches the compiled grammar as blimp.dylib in ~/.cache/tree-sitter/lib,
# one file for every checkout, and reuses it while it is newer than parser.c;
# so another worktree's grammar could be what got tested. A private libdir.
suite "tree-sitter test" sh -c "d=\$(mktemp -d) && cd tree-sitter-blimp && TREE_SITTER_LIBDIR=\$d $TREE_SITTER test; rc=\$?; rm -rf \"\$d\"; exit \$rc"
suite "build blimp-compile (LLVM ${LLVM:-found by build.zig})" build_compiler
suite "compiled fixtures" compiler_suite sh test/compiled/run.sh
suite "diff harness" compiler_suite python3 -B test/diff/run.py

echo
if [ ${#failed[@]} -gt 0 ]; then
    echo "FAILED: ${failed[*]}"
    exit 1
fi
echo "all suites passed"
