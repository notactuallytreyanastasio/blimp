const std = @import("std");
const Value = @import("value.zig").Value;

/// Variable environment with lexical scope support.
/// Uses a stack of scopes, each mapping variable names to values.
/// Follows the same pattern as TypeEnv in types.zig.
pub const Environment = struct {
    scopes: std.ArrayList(Scope),
    /// Binding lists left behind by popped scopes, kept for the next push.
    /// Every call pushes a scope and pops it again, and the evaluator runs on
    /// an arena that frees nothing, so without this list a call leaves its
    /// binding buffer in the allocator for the rest of the run.
    free_scopes: std.ArrayList(std.ArrayList(Binding)),
    allocator: std.mem.Allocator,

    pub const Binding = struct {
        name: []const u8,
        val: *const Value,
    };

    pub const Scope = struct {
        bindings: std.ArrayList(Binding),
        /// One bit per name in this scope, by hash, maintained by `defineIn`.
        /// A lookup whose bit is clear skips the scope without comparing a
        /// single string.
        ///
        /// This is not a micro-optimisation.  A Blimp closure sees its
        /// caller's locals, so resolving a global from N frames deep walks
        /// all N scopes, and a recursion N deep does that N times: finding
        /// `fib` was a quarter of the time in fib(35).  A false positive
        /// costs a search that would have happened anyway; there are no
        /// false negatives, so what the walk finds does not change.
        names: u64 = 0,
    };

    /// The bit this name claims in a scope's `names`.  Public because anything
    /// that builds a Scope without going through `define` has to rebuild the
    /// mask itself — gc.zig does, and the gc tests fail loudly if it stops.  Two loads and three
    /// arithmetic ops: a real hash costs more than the string comparisons it
    /// saves, because most lookups hit the innermost scope on the first try.
    pub fn nameBit(name: []const u8) u64 {
        if (name.len == 0) return 1;
        const first: u64 = name[0];
        const last: u64 = name[name.len - 1];
        const h = first ^ (last << 2) ^ (@as(u64, name.len) << 4);
        return @as(u64, 1) << @as(u6, @truncate(h));
    }

    pub fn init(allocator: std.mem.Allocator) Environment {
        var env = Environment{
            .scopes = .{ .items = &.{}, .capacity = 0 },
            .free_scopes = .{ .items = &.{}, .capacity = 0 },
            .allocator = allocator,
        };
        // Push the global scope
        env.pushScope();
        return env;
    }

    /// Push a new scope (entering a block), reusing a recycled binding list
    /// when one is going spare.
    pub fn pushScope(self: *Environment) void {
        const bindings = self.free_scopes.pop() orelse
            std.ArrayList(Binding){ .items = &.{}, .capacity = 0 };
        self.scopes.append(self.allocator, .{ .bindings = bindings }) catch {};
    }

    /// Pop the current scope (leaving a block).
    pub fn popScope(self: *Environment) void {
        if (self.scopes.pop()) |scope| self.recycle(scope);
    }

    /// Keep a popped scope's binding buffer for the next push.  Dropping it
    /// instead is what made a deep recursion grow without bound.
    fn recycle(self: *Environment, scope: Scope) void {
        // `names` belongs to the scope, not to the buffer being kept.
        var bindings = scope.bindings;
        bindings.clearRetainingCapacity();
        self.free_scopes.append(self.allocator, bindings) catch {};
    }

    /// Number of scopes on the stack. Callers record this to pop back to it.
    pub fn depth(self: *const Environment) usize {
        return self.scopes.items.len;
    }

    /// Pop scopes until only `n` remain (no-op if already at or below n).
    pub fn popTo(self: *Environment, n: usize) void {
        while (self.scopes.items.len > n) {
            if (self.scopes.pop()) |scope| self.recycle(scope);
        }
    }

    /// Merge every scope above index `base` into scopes[base], inner bindings
    /// winning, then pop them. The visible bindings are unchanged, there is
    /// just one scope holding them. Used when a closure's frame is reused for
    /// a tail call so the callee still sees everything the caller could see.
    pub fn collapseTo(self: *Environment, base: usize) void {
        if (base + 1 >= self.scopes.items.len) return;
        var i: usize = base + 1;
        while (i < self.scopes.items.len) : (i += 1) {
            for (self.scopes.items[i].bindings.items) |b| {
                self.defineIn(base, b.name, b.val);
            }
        }
        while (self.scopes.items.len > base + 1) {
            if (self.scopes.pop()) |scope| self.recycle(scope);
        }
    }

    /// Define (or update) a variable in the current scope.
    pub fn define(self: *Environment, name: []const u8, value: *const Value) void {
        if (self.scopes.items.len == 0) return;
        self.defineIn(self.scopes.items.len - 1, name, value);
    }

    fn defineIn(self: *Environment, index: usize, name: []const u8, value: *const Value) void {
        const scope = &self.scopes.items[index];
        scope.names |= nameBit(name);
        // Check for existing binding to update
        for (scope.bindings.items) |*binding| {
            if (std.mem.eql(u8, binding.name, name)) {
                binding.val = value;
                return;
            }
        }
        scope.bindings.append(self.allocator, .{ .name = name, .val = value }) catch {};
    }

    /// Return all bindings visible from the current scope (innermost wins).
    pub fn allBindings(self: *const Environment, allocator: std.mem.Allocator) []const Binding {
        var seen = std.ArrayList([]const u8){ .items = &.{}, .capacity = 0 };
        var result = std.ArrayList(Binding){ .items = &.{}, .capacity = 0 };

        // Walk from innermost to outermost
        var i: usize = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            for (self.scopes.items[i].bindings.items) |binding| {
                var already = false;
                for (seen.items) |s| {
                    if (std.mem.eql(u8, s, binding.name)) {
                        already = true;
                        break;
                    }
                }
                if (!already) {
                    seen.append(allocator, binding.name) catch {};
                    result.append(allocator, binding) catch {};
                }
            }
        }
        return result.items;
    }

    /// Look up a variable, searching from innermost to outermost scope.
    pub fn lookup(self: *const Environment, name: []const u8) ?*const Value {
        const bit = nameBit(name);
        var i: usize = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            const scope = self.scopes.items[i];
            if (scope.names & bit == 0) continue;
            // Search backwards for most recent binding
            var j: usize = scope.bindings.items.len;
            while (j > 0) {
                j -= 1;
                if (std.mem.eql(u8, scope.bindings.items[j].name, name)) {
                    return scope.bindings.items[j].val;
                }
            }
        }
        return null;
    }
};

// ============================================================
// Tests
// ============================================================

test "define and lookup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Environment.init(alloc);
    const val = try alloc.create(Value);
    val.* = Value{ .integer = 42 };
    env.define("x", val);

    const result = env.lookup("x");
    try std.testing.expect(result != null);
    try std.testing.expect(result.?.eql(Value{ .integer = 42 }));
}

test "lookup missing returns null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Environment.init(alloc);
    try std.testing.expect(env.lookup("missing") == null);
}

test "nested scopes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Environment.init(alloc);
    const val_x = try alloc.create(Value);
    val_x.* = Value{ .integer = 1 };
    env.define("x", val_x);

    env.pushScope();
    const val_y = try alloc.create(Value);
    val_y.* = Value{ .integer = 2 };
    env.define("y", val_y);

    // Inner scope sees both x and y
    try std.testing.expect(env.lookup("x") != null);
    try std.testing.expect(env.lookup("y") != null);

    env.popScope();
    // After pop, y is gone
    try std.testing.expect(env.lookup("x") != null);
    try std.testing.expect(env.lookup("y") == null);
}

test "collapseTo keeps the visible bindings in one scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Environment.init(alloc);
    const one = try alloc.create(Value);
    one.* = Value{ .integer = 1 };
    const two = try alloc.create(Value);
    two.* = Value{ .integer = 2 };
    const three = try alloc.create(Value);
    three.* = Value{ .integer = 3 };

    env.define("g", one);
    const base = env.depth();
    env.pushScope();
    env.define("x", one);
    env.define("y", one);
    env.pushScope();
    env.define("x", two);
    env.pushScope();
    env.define("z", three);

    env.collapseTo(base);
    try std.testing.expectEqual(base + 1, env.depth());
    try std.testing.expect(env.lookup("x").?.eql(Value{ .integer = 2 }));
    try std.testing.expect(env.lookup("y").?.eql(Value{ .integer = 1 }));
    try std.testing.expect(env.lookup("z").?.eql(Value{ .integer = 3 }));
    try std.testing.expect(env.lookup("g").?.eql(Value{ .integer = 1 }));

    env.popTo(base);
    try std.testing.expectEqual(base, env.depth());
    try std.testing.expect(env.lookup("x") == null);
    try std.testing.expect(env.lookup("g") != null);
}

test "a pushed and popped scope costs nothing the second time" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Environment.init(alloc);
    const val = try alloc.create(Value);
    val.* = Value{ .integer = 1 };

    // Let the scope stack and the first binding list reach their size.
    for (0..64) |_| {
        env.pushScope();
        env.define("x", val);
        env.popScope();
    }
    const settled = arena.queryCapacity();

    for (0..10_000) |_| {
        env.pushScope();
        env.define("x", val);
        env.popScope();
    }

    // Every call pushes a scope.  If popping dropped the binding list, this
    // loop would leave 10_000 of them in the arena.
    try std.testing.expectEqual(settled, arena.queryCapacity());
}

test "a name in an outer scope is found through many inner ones" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Environment.init(alloc);
    const target = try alloc.create(Value);
    target.* = Value{ .integer = 99 };
    const noise = try alloc.create(Value);
    noise.* = Value{ .integer = 1 };

    env.define("target", target);
    for (0..64) |i| {
        env.pushScope();
        // Names chosen to land on assorted bits, including whatever `target`
        // hashes to: a scope that claims the bit must still be searched, and
        // one that does not must still be skipped correctly.
        const name = try std.fmt.allocPrint(alloc, "n{d}", .{i});
        env.define(name, noise);
    }

    try std.testing.expectEqual(@as(i64, 99), env.lookup("target").?.integer);
    try std.testing.expect(env.lookup("absent") == null);

    // And still after the frames above it are collapsed into one.
    env.collapseTo(1);
    try std.testing.expectEqual(@as(i64, 99), env.lookup("target").?.integer);
    try std.testing.expectEqual(@as(i64, 1), env.lookup("n7").?.integer);
}

test "inner scope shadows outer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Environment.init(alloc);
    const val1 = try alloc.create(Value);
    val1.* = Value{ .integer = 1 };
    env.define("x", val1);

    env.pushScope();
    const val2 = try alloc.create(Value);
    val2.* = Value{ .string = "shadowed" };
    env.define("x", val2);
    try std.testing.expect(env.lookup("x").?.eql(Value{ .string = "shadowed" }));

    env.popScope();
    try std.testing.expect(env.lookup("x").?.eql(Value{ .integer = 1 }));
}
