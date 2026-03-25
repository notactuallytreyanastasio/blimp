#!/bin/bash
# Benchmark runner: Blimp vs C vs Zig vs Rust vs Python vs Ruby
set -e
cd "$(dirname "$0")"

BLIMP_COMPILE="../zig-out/bin/blimp-compile"
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

echo "=== Compiling ==="

# C (-O2)
cc -O2 fib.c -o "$TMPDIR/fib_c"
cc -O2 btree.c -o "$TMPDIR/btree_c"
cc -O2 knn.c -o "$TMPDIR/knn_c"
echo "  C: done"

# Zig (-OReleaseFast)
zig build-exe fib.zig -OReleaseFast -femit-bin="$TMPDIR/fib_zig" 2>/dev/null
zig build-exe btree.zig -OReleaseFast -femit-bin="$TMPDIR/btree_zig" 2>/dev/null
zig build-exe knn.zig -OReleaseFast -femit-bin="$TMPDIR/knn_zig" 2>/dev/null
echo "  Zig: done"

# Rust (release optimized)
rustc -O fib.rs -o "$TMPDIR/fib_rs" 2>/dev/null
rustc -O btree.rs -o "$TMPDIR/btree_rs" 2>/dev/null
rustc -O knn.rs -o "$TMPDIR/knn_rs" 2>/dev/null
echo "  Rust: done"

# Blimp (LLVM native)
$BLIMP_COMPILE ../examples/bench_fib.blimp -o "$TMPDIR/fib_blimp"
$BLIMP_COMPILE ../examples/bench_btree.blimp -o "$TMPDIR/btree_blimp"
$BLIMP_COMPILE ../examples/bench_knn.blimp -o "$TMPDIR/knn_blimp"
echo "  Blimp: done"

echo ""

# Time a command, return milliseconds
bench() {
    local label="$1"
    shift
    # Run 3 times, take median
    local times=()
    for i in 1 2 3; do
        local start=$(python3 -c "import time; print(int(time.monotonic_ns()))")
        local result=$("$@" 2>/dev/null)
        local end=$(python3 -c "import time; print(int(time.monotonic_ns()))")
        local ms=$(( (end - start) / 1000000 ))
        times+=($ms)
    done
    # Sort and take median
    IFS=$'\n' sorted=($(sort -n <<<"${times[*]}")); unset IFS
    local median=${sorted[1]}
    printf "  %-12s %6d ms  (result: %s)\n" "$label" "$median" "$result"
}

echo "=== Fibonacci (fib 40) ==="
bench "C"      "$TMPDIR/fib_c"
bench "Zig"    "$TMPDIR/fib_zig"
bench "Rust"   "$TMPDIR/fib_rs"
bench "Blimp"  "$TMPDIR/fib_blimp"
bench "Python"  python3 fib.py
bench "Ruby"    ruby fib.rb
echo ""

echo "=== Binary Tree (depth 25) ==="
bench "C"      "$TMPDIR/btree_c"
bench "Zig"    "$TMPDIR/btree_zig"
bench "Rust"   "$TMPDIR/btree_rs"
bench "Blimp"  "$TMPDIR/btree_blimp"
bench "Python"  python3 btree.py
bench "Ruby"    ruby btree.rb
echo ""

echo "=== KNN Grid (1000x1000) ==="
bench "C"      "$TMPDIR/knn_c"
bench "Zig"    "$TMPDIR/knn_zig"
bench "Rust"   "$TMPDIR/knn_rs"
bench "Blimp"  "$TMPDIR/knn_blimp"
bench "Python"  python3 knn.py
bench "Ruby"    ruby knn.rb
