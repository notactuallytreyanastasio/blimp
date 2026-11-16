#!/bin/bash
# Compile-and-run fixtures for blimp-compile.
#
#   test/compiled/run.sh [path/to/blimp-compile]          check every fixture
#   test/compiled/run.sh --interp path/to/blimp FILE...   what the interpreter
#                                                         says, same format
#
# Each NAME.blimp has a NAME.expected: the compiled program's stdout, stderr
# and exit status (or blimp-compile's own failure), with ANSI colour stripped.
# A compiled program prints its last top-level value; under --interp the last
# line is wrapped in puts() so the two columns can be compared.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

strip() { sed $'s/\x1b\\[[0-9;]*m//g'; }

compiled() { # $1 = blimp-compile, $2 = fixture
    local f="$2" bin="$tmp/prog"
    if ! (cd "$(dirname "$f")" && "$1" "$(basename "$f")" -o "$bin") >"$tmp/cout" 2>"$tmp/cerr"; then
        echo "--- compile failed"
        strip <"$tmp/cerr"
        strip <"$tmp/cout"
        return
    fi
    "$bin" >"$tmp/out" 2>"$tmp/err"
    local code=$?
    echo "--- stdout"; strip <"$tmp/out"
    echo "--- stderr"; strip <"$tmp/err"
    echo "--- exit $code"
}

interp() { # $1 = blimp, $2 = fixture
    local f="$2" w="$tmp/$(basename "$2")"
    python3 -c 'import sys
L=open(sys.argv[1]).read().rstrip("\n").split("\n")
L[-1]="puts("+L[-1]+")"
open(sys.argv[2],"w").write("\n".join(L)+"\n")' "$f" "$w"
    "$1" "$w" >"$tmp/out" 2>"$tmp/err"
    local code=$?
    echo "--- stdout"; strip <"$tmp/out"
    echo "--- stderr"; strip <"$tmp/err"
    echo "--- exit $code"
}

if [ "${1:-}" = "--interp" ]; then
    b="$2"; shift 2
    for f in "$@"; do echo "=== $(basename "$f")"; interp "$b" "$f"; done
    exit 0
fi

bc="${1:-$here/../../zig-out/bin/blimp-compile}"
bc="$(cd "$(dirname "$bc")" && pwd)/$(basename "$bc")"
pass=0; fail=0

# `--run` must hand back the program's exit status, not 0.
(cd "$tmp" && "$bc" "$here/bubble_uncaught.blimp" --run >/dev/null 2>&1)
code=$?
if [ "$code" -eq 1 ]; then
    pass=$((pass + 1))
else
    fail=$((fail + 1))
    echo "FAIL --run exit status: an uncaught bubble under --run exited $code, want 1"
fi

for f in "$here"/*.blimp; do
    name="$(basename "$f" .blimp)"
    compiled "$bc" "$f" >"$tmp/actual"
    if diff -u "$here/$name.expected" "$tmp/actual" >"$tmp/diff"; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        echo "FAIL $name"
        sed 's/^/    /' "$tmp/diff"
    fi
done
echo "compiled fixtures: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
