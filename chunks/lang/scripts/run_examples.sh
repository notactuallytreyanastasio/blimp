#!/usr/bin/env bash
# Every examples/*.blimp run as a program, the way a newcomer runs it:
# `blimp examples/NAME.blimp`, stdin closed. Each must exit 0 unless it is
# in the table below. examples/errors/ fail on purpose and are not run.
#
#   scripts/run_examples.sh            (from anywhere; make check runs it)
#   BLIMP=/path/to/blimp scripts/run_examples.sh
#
# Exits 1 and names each example that broke the rule, including one in the
# table that no longer does what its line says.
set -u
cd "$(dirname "$0")/.."
BLIMP=${BLIMP:-./zig-out/bin/blimp}

# The exceptions, all of them. One line each: name, mode, reason.
#   fail  must exit non-zero; when it starts to exit 0 this suite says so
#   skip  not run, for the reason given
#   stub  run from a copy in a temp directory with a `claude` on PATH that
#         answers nothing, so a Hole it reaches is not filled, nothing is
#         sent to a model and no file is rewritten; must exit 0
EXCEPTIONS='
bank_account      fail  syntax sketch: `expr orelse bubble` does not parse
checkout          fail  syntax sketch: a leading `|>` on the next line does not parse
content_pipeline  skip  needs the claude CLI: its Classifier Hole answers nil without it, and Scorer stops on the nil
game_rules        stub  Hole demo: a Hole runs `claude -p` and writes the answer into the file
rate_limiter      stub  Hole demo: a Hole runs `claude -p` and writes the answer into the file
jetstream         skip  connects to the Bluesky firehose and reads it for 30 seconds
bench_fib         skip  fib(40) benchmark: about 20 seconds, and fib is covered in test/diff/corpus
'

mode_of() {
    printf '%s\n' "$EXCEPTIONS" | awk -v n="$1" '$1 == n { print $2 }'
}

stub_dir=$(mktemp -d)
trap 'rm -rf "$stub_dir"' EXIT
mkdir -p "$stub_dir/bin" "$stub_dir/run"
printf '#!/bin/sh\nexit 0\n' > "$stub_dir/bin/claude"
chmod +x "$stub_dir/bin/claude"
blimp_abs=$(cd "$(dirname "$BLIMP")" && pwd)/$(basename "$BLIMP")

rc=0
seen=()
for f in examples/*.blimp; do
    name=$(basename "$f" .blimp)
    mode=$(mode_of "$name")
    seen+=("$name")
    case "$mode" in
    skip)
        printf 'skip  %s\n' "$name"
        continue
        ;;
    stub)
        cp "$f" "$stub_dir/run/$name.blimp"
        out=$(cd "$stub_dir/run" && PATH="$stub_dir/bin:$PATH" "$blimp_abs" "$name.blimp" </dev/null 2>&1)
        status=$?
        ;;
    *)
        out=$("$BLIMP" "$f" </dev/null 2>&1)
        status=$?
        ;;
    esac
    if [ "$mode" = fail ]; then
        if [ $status -eq 0 ]; then
            printf 'FAIL  %s exits 0 now; take it out of the exceptions in scripts/run_examples.sh\n' "$name"
            rc=1
        else
            printf 'ok    %s (fails, as listed: exit %d)\n' "$name" "$status"
        fi
    elif [ $status -eq 0 ]; then
        printf 'ok    %s\n' "$name"
    else
        printf 'FAIL  %s exited %d:\n' "$name" "$status"
        printf '%s\n' "$out" | sed 's/\x1b\[[0-9;]*m//g' | grep -v '^[[:space:]]*$' | head -6 | sed 's/^/      /'
        rc=1
    fi
done

# A listed name with no file is a table that has rotted.
for listed in $(printf '%s\n' "$EXCEPTIONS" | awk 'NF { print $1 }'); do
    case " ${seen[*]} " in
    *" $listed "*) ;;
    *)
        printf 'FAIL  %s is in the exceptions but examples/%s.blimp does not exist\n' "$listed" "$listed"
        rc=1
        ;;
    esac
done
exit $rc
