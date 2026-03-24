#!/bin/bash
# Run all error examples to demonstrate Blimp's error messages
# Each file triggers a specific error with helpful output

cd "$(dirname "$0")/../.."

echo "========================================"
echo "  Blimp Error Message Showcase"
echo "========================================"

for f in examples/errors/[0-9]*.blimp; do
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    head -3 "$f" | grep "^# " | tail -1 | sed 's/^# /  /'
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    # Strip comments and blank lines, feed to REPL
    grep -v "^#" "$f" | grep -v "^$" | ./zig-out/bin/blimp --repl 2>&1 | grep -A 18 "^-- " | head -18
    echo ""
done

echo "========================================"
echo "  Done."
echo "========================================"
