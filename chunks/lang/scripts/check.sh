#!/usr/bin/env bash
# Every test suite in chunks/lang, against an interpreter and a blimp.wasm
# built from this tree. Exits 0 only if all of them pass; otherwise it names
# each suite that failed and exits 1.
#
#   make check                   (or scripts/check.sh from anywhere)
#   ZIG=/path/to/zig make check  (default: `zig`, which mise resolves from
#                                 .tool-versions to 0.16.0 inside chunks/lang)
#
# Needs: zig 0.16.0, node, python3, npx (tree-sitter-cli is fetched by
# version). A missing tool is a failed suite, not a skipped one.
set -u
cd "$(dirname "$0")/.."

ZIG=${ZIG:-zig}
TREE_SITTER=${TREE_SITTER:-npx --yes -p tree-sitter-cli@0.25.10 tree-sitter}
BLIMP=./zig-out/bin/blimp
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

# Was a segfault (0xaaaaaaaaaaaaaaaa in evalMessageSend); it prints 1 now.
regression_spawn_in_send_arg() {
    local out
    out=$("$BLIMP" test/regression_spawn_in_send_arg.blimp) || return 1
    [ "$out" = "1" ] || { echo "expected 1, got: $out"; return 1; }
}

suite "zig build test" "$ZIG" build test --summary all
suite "blimp test test" "$BLIMP" test test
suite "blimp test lib" "$BLIMP" test lib
suite "examples --test" examples_with_tests
suite "runner reports failure" runner_reports_failure
suite "regression_spawn_in_send_arg" regression_spawn_in_send_arg
suite "node web/test" env BLIMP_WASM="$PWD/zig-out/web/blimp.wasm" node --test web/test/
suite "python scripts" sh -c 'cd scripts && python3 -B -m unittest trace_receipt_test.py'
suite "tree-sitter test" sh -c "cd tree-sitter-blimp && $TREE_SITTER test"

echo
if [ ${#failed[@]} -gt 0 ]; then
    echo "FAILED: ${failed[*]}"
    exit 1
fi
echo "all suites passed"
