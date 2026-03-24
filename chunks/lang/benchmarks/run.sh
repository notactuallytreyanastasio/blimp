#!/bin/bash
# Blimp benchmark suite: compare against Rust, Python, Elixir
# Run from chunks/lang/benchmarks/

set -e
cd "$(dirname "$0")"

echo "========================================"
echo "  Blimp Benchmark Suite"
echo "========================================"
echo ""

# Build Blimp
echo "Building Blimp..."
cd ..
zig build 2>/dev/null
cd benchmarks

# Build Rust benchmarks
echo "Building Rust benchmarks..."
rustc -O fib.rs -o fib_rs 2>/dev/null
rustc -O spawn.rs -o spawn_rs 2>/dev/null
rustc -O ring.rs -o ring_rs 2>/dev/null

echo ""
echo "========================================"
echo "  1. Fibonacci (fib(30) - CPU bound)"
echo "========================================"
echo ""

echo -n "Blimp (interpreter):  "
time_start=$(python3 -c "import time; print(time.time())")
result=$(echo 'def fib(n) do
  situation n do
    0 -> 0
    1 -> 1
    _ -> fib(n - 1) + fib(n - 2)
  end
end
fib(30)' | ../zig-out/bin/blimp --repl 2>&1 | grep "^blimp> => " | tail -1 | sed 's/blimp> => //')
time_end=$(python3 -c "import time; print(time.time())")
elapsed=$(python3 -c "print(f'{($time_end - $time_start)*1000:.0f}ms')")
echo "$result ($elapsed)"

echo -n "Python:               "
python3 fib.py

echo -n "Elixir:               "
elixir fib.exs

echo -n "Rust:                 "
./fib_rs

echo ""
echo "========================================"
echo "  2. Actor Spawn + Send (100 actors)"
echo "========================================"
echo ""

echo -n "Blimp (interpreter):  "
time_start=$(python3 -c "import time; print(time.time())")
echo 'actor Counter do
  state count: Int :: 0
  on :increment do
    become count: count + 1
    reply count + 1
  end
end
for i in range(1, 100) do
  c = spawn Counter
  c <- :increment
end' | ../zig-out/bin/blimp --repl 2>&1 > /dev/null
time_end=$(python3 -c "import time; print(time.time())")
elapsed=$(python3 -c "print(f'{($time_end - $time_start)*1000:.0f}ms')")
echo "100 actors ($elapsed)"

echo -n "Python:               "
python3 spawn.py

echo -n "Elixir:               "
elixir spawn.exs

echo -n "Rust:                 "
./spawn_rs

echo ""
echo "========================================"
echo "  3. Ring (10 actors x 100 rounds = 1000 sends)"
echo "========================================"
echo ""

echo -n "Blimp (interpreter):  "
time_start=$(python3 -c "import time; print(time.time())")
result=$(cat ring.blimp | ../zig-out/bin/blimp --repl 2>&1 | grep "^blimp> => " | tail -1 | sed 's/blimp> => //')
time_end=$(python3 -c "import time; print(time.time())")
elapsed=$(python3 -c "print(f'{($time_end - $time_start)*1000:.0f}ms')")
echo "$result ($elapsed)"

echo -n "Python:               "
python3 ring.py

echo -n "Elixir:               "
elixir ring.exs

echo -n "Rust:                 "
./ring_rs

echo ""
echo "========================================"
echo "  Summary"
echo "========================================"
echo ""
echo "Blimp is a tree-walking interpreter."
echo "The comparison is: how slow is interpretation"
echo "vs compiled/VM languages? And how does actor"
echo "overhead compare?"
echo ""

# Cleanup
rm -f fib_rs spawn_rs ring_rs
