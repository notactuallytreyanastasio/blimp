//! What a running program costs the evaluator heap.
//!
//! The tree-walking evaluator allocates from an arena and frees nothing until
//! the run ends, so anything it allocates per call is retained per call.  That
//! is what turned `fib(30)` into 832 MB and `fib(40)` into roughly 100 GB.
//!
//! These tests measure the arena, not the process: they say how many bytes a
//! program costs, which is the thing that has to stay flat.

const std = @import("std");
const Parser = @import("parser.zig").Parser;
const Evaluator = @import("eval.zig").Evaluator;
const Value = @import("value.zig").Value;

/// Bytes of evaluator heap that running `source` costs.  The AST gets its own
/// allocator so only the evaluator's own appetite is measured.
fn heapCost(source: []const u8) !usize {
    var code = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer code.deinit();
    var heap = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer heap.deinit();

    var parser = Parser.init(code.allocator(), source);
    const nodes = try parser.parseFile();

    var eval = Evaluator.init(heap.allocator());
    const before = heap.queryCapacity();
    for (nodes) |node| _ = try eval.eval(node);
    return heap.queryCapacity() - before;
}

const spin =
    \\def spin(n: Int) do
    \\  situation n do
    \\    0 -> 0
    \\    _ -> spin(n - 1)
    \\  end
    \\end
    \\
;

const fib =
    \\def fib(n: Int) do
    \\  situation n do
    \\    0 -> 0
    \\    1 -> 1
    \\    _ -> fib(n - 1) + fib(n - 2)
    \\  end
    \\end
    \\
;

test "a tail-recursive loop over interned values costs nothing per iteration" {
    // Every value here is in the interned range, so an iteration has nothing
    // left to allocate: no result value, no scope, no argument vector.
    const short = try heapCost(spin ++ "spin(100)");
    const long = try heapCost(spin ++ "spin(4000)");
    try std.testing.expectEqual(short, long);
}

test "a deep recursion costs its results, not its calls" {
    // fib(24) is 92735 calls.  Each used to cost ~360 bytes of scope, argument
    // vector and boxed small integers: 33 MB.  What is left is the handful of
    // results too large to intern.
    const cost = try heapCost(fib ++ "fib(24)");
    try std.testing.expect(cost < 128 * 1024);
}

test "eighteen times the calls is not eighteen times the memory" {
    const small = try heapCost(fib ++ "fib(18)");
    const large = try heapCost(fib ++ "fib(24)");
    // fib(24) makes 18x the calls of fib(18).  Growth that tracks the call
    // count is the bug this guards.
    try std.testing.expect(large < small * 2);
}

test "a value is at most four words" {
    // Every value a run allocates is held until the run ends, so the width of
    // a Value is paid per surviving arithmetic step.  `closure` and
    // `view_node` are boxed to keep it here; putting either back inline made
    // an integer 72 bytes and a million-iteration loop 293 MB.
    try std.testing.expect(@sizeOf(Value) <= 4 * @sizeOf(usize));
}
