#!/usr/bin/env bash
# Every examples/*.blimp run as a program, the way a newcomer runs it:
# `blimp NAME.blimp`, stdin closed. Each must exit 0 within the time bound
# unless it is in the table below. examples/errors/ fail on purpose and are
# not run.
#
#   scripts/run_examples.sh            (from anywhere; make check runs it)
#   BLIMP=/path/to/blimp EXAMPLE_TIMEOUT=20 scripts/run_examples.sh
#
# Exits 1 and names each example that broke the rule, including one that
# ran past the bound and one in the table that no longer does what its line
# says.
#
# Holes. A Hole the interpreter reaches runs `claude -p <prompt>` (whatever
# `claude` is first on PATH) and patchHole writes a non-empty answer into
# the .blimp file it was run from. So no example here is run as itself:
# every one is run from a copy in a temp directory, with a `claude` first on
# PATH that answers nothing and appends the example's name to a log. That
# holds for every file, listed or not, Hole or not, so a new example with a
# reachable Hole cannot reach a model or rewrite itself. Either guard alone
# would do (an empty answer is never patched in; a patched copy is thrown
# away); both are kept so that neither depends on the other's details.
# Examples whose Holes were reached are named at the end.
#
# Time. Each run is bounded by EXAMPLE_TIMEOUT seconds (default 20) with
# perl's alarm, because macOS before 15 has no timeout(1) and perl is in
# every macOS and Linux base system. A run past the bound is killed and is
# a failure that names the example and the bound.
set -u
cd "$(dirname "$0")/.."
BLIMP=${BLIMP:-./zig-out/bin/blimp}
EXAMPLE_TIMEOUT=${EXAMPLE_TIMEOUT:-20}

# The exceptions, all of them. One line each: name, mode, reason.
#   fail  must exit non-zero; when it starts to exit 0 this suite says so
#   skip  not run, for the reason given
EXCEPTIONS='
bank_account      fail  syntax sketch: `expr orelse bubble` does not parse
checkout          fail  syntax sketch: a leading `|>` on the next line does not parse
content_pipeline  fail  needs a real claude: its Classifier Hole answers nil here, and Scorer stops on the nil
jetstream         skip  connects to the Bluesky firehose and reads it for 30 seconds
bench_fib         skip  fib(40) benchmark: 19 to 21 s interpreted, at the 20 s bound, so it would pass or fail by load; fib is in test/diff/corpus
'

mode_of() {
    printf '%s\n' "$EXCEPTIONS" | awk -v n="$1" '$1 == n { print $2 }'
}

# run_bounded SECONDS CMD...: CMD's exit status, or 124 if it ran past
# SECONDS, in which case it is killed (SIGKILL, so it cannot ignore it).
run_bounded() {
    perl -e '
        my $t = shift;
        my $pid = fork() // die "fork: $!";
        if ($pid == 0) { exec @ARGV or die "exec $ARGV[0]: $!" }
        local $SIG{ALRM} = sub { kill "KILL", $pid; waitpid $pid, 0; exit 124 };
        alarm $t;
        waitpid $pid, 0;
        exit($? & 127 ? 128 + ($? & 127) : $? >> 8);
    ' "$@"
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/run"
cat > "$work/bin/claude" <<EOF
#!/bin/sh
# Stands in for the claude CLI: answers nothing, and says who asked.
echo "\${BLIMP_EXAMPLE:-?}" >> "$work/claude-calls"
exit 0
EOF
chmod +x "$work/bin/claude"
: > "$work/claude-calls"
blimp_abs=$(cd "$(dirname "$BLIMP")" && pwd)/$(basename "$BLIMP")

rc=0
seen=()
for f in examples/*.blimp; do
    name=$(basename "$f" .blimp)
    mode=$(mode_of "$name")
    seen+=("$name")
    if [ "$mode" = skip ]; then
        printf 'skip  %s\n' "$name"
        continue
    fi
    cp "$f" "$work/run/$name.blimp"
    out=$(cd "$work/run" && BLIMP_EXAMPLE=$name PATH="$work/bin:$PATH" \
        run_bounded "$EXAMPLE_TIMEOUT" "$blimp_abs" "$name.blimp" </dev/null 2>&1)
    status=$?
    if [ $status -eq 124 ]; then
        printf 'FAIL  %s ran past %ss and was killed\n' "$name" "$EXAMPLE_TIMEOUT"
        rc=1
    elif [ "$mode" = fail ]; then
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

if [ -s "$work/claude-calls" ]; then
    printf 'Holes reached (answered by the stub, nothing written back): %s\n' \
        "$(sort "$work/claude-calls" | uniq -c | awk '{ printf "%s%s x%s", sep, $2, $1; sep = ", " }')"
fi
exit $rc
