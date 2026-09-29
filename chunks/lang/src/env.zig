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
        /// What a closure captured, borrowed from the closure rather than
        /// copied into `bindings`.
        ///
        /// Copying them in cost a `defineIn` each, and `defineIn` scans the
        /// scope for an existing name, so installing a closure's captures was
        /// quadratic in how many there were. Every translated Temper program
        /// carries the ~400-definition prelude, every one of those definitions
        /// captures every other, and so every call bound 400 names at a cost
        /// of 80,000 string comparisons. A bare 1600-iteration loop took 1ms
        /// on its own and 2409ms with the prelude in the file.
        ///
        /// Borrowing is safe because the closure outlives the call -- it is
        /// the callee -- and `gc.compact` runs only between REPL evaluations,
        /// when the only scope is the global one and it has no captures.
        captured: []const Value.CapturedBinding = &.{},
        /// The `names` mask for [captured], computed once when the closure was
        /// built rather than per call.
        captured_names: u64 = 0,
        /// Where the current callee's own bindings start.
        ///
        /// A tail call reuses its frame, so `bindings` below this index belong
        /// to a callee that has already returned. Those are the caller's
        /// locals, which a Blimp closure can see -- but they must not shadow
        /// the *current* callee's captures, which is what copying the captures
        /// in used to prevent: `defineIn` overwrote the stale entry.
        ///
        /// Dropping that gave the regex matcher a continuation from the wrong
        /// frame. `temper_rx_seq_at` ran off the end of its node list and kept
        /// going, because the `k` it called was a stale `k` rather than the
        /// one it had captured:
        ///
        ///     seq_at idx=2 pos=2 n=2
        ///     seq_at idx=3 pos=2 n=2
        ///     seq_at idx=4 pos=2 n=2
        own_base: usize = 0,
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

    /// Lend the current scope a closure's captured bindings.
    ///
    /// They are visible to lookup but are not in `bindings`, so a parameter or
    /// a local defined afterwards shadows a capture of the same name, which is
    /// the order `define` gave before.
    pub fn lendCaptured(self: *Environment, captured: []const Value.CapturedBinding, names: u64) void {
        if (self.scopes.items.len == 0) return;
        const index = self.scopes.items.len - 1;
        const existing = self.scopes.items[index].captured;
        // A tail call reuses the frame, so the scope may already have been
        // lent the previous callee's captures. A Blimp closure sees its
        // caller's frame, so those cannot simply be dropped: they are folded
        // into the scope's own bindings first, where a name the scope already
        // binds wins. Self-recursion lends the same slice every time and skips
        // all of this.
        if (existing.ptr == captured.ptr and existing.len == captured.len) {
            // The same closure re-entering its own frame, which is what every
            // tail-recursive loop does. Its previous parameters and locals are
            // about to be replaced, so the region is reused rather than a
            // second copy appended -- otherwise a loop grows its frame once
            // per iteration, which `memory_test` measures and rejects.
            const scope = &self.scopes.items[index];
            scope.bindings.shrinkRetainingCapacity(scope.own_base);
            return;
        }
        if (existing.len != 0) {
            // A different callee taking over the frame. What the last one
            // captured becomes part of what it leaves behind, since a Blimp
            // closure can see the frame it was called from. Dropping these
            // gets a continuation from the wrong closure, which the regex
            // engine reports as
            //
            //     Handler :fn expects 4 argument(s), got 2.
            //
            // Only the outgoing callee's *own* region is checked for a name
            // that would shadow one of these: names within `existing` are
            // unique, and anything below that region is older still, so a
            // capture appended here is right to win over it. Checking all of
            // `bindings` made this quadratic, which is the cost the rest of
            // this commit is about removing.
            const own_len = self.scopes.items[index].bindings.items.len;
            const own_base = self.scopes.items[index].own_base;
            outer: for (existing) |b| {
                for (self.scopes.items[index].bindings.items[own_base..own_len]) |binding| {
                    if (std.mem.eql(u8, binding.name, b.name)) continue :outer;
                }
                const sc = &self.scopes.items[index];
                sc.names |= nameBit(b.name);
                sc.bindings.append(self.allocator, .{ .name = b.name, .val = b.val }) catch {};
            }
        }
        const scope = &self.scopes.items[index];
        scope.captured = captured;
        scope.captured_names = names;
        // Everything already in the frame belongs to whoever ran here before.
        scope.own_base = scope.bindings.items.len;
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
            // A collapsed scope's captures are copied in, because the scope
            // they were lent to is about to go and `base` may have captures of
            // its own. This is the one place that still pays the old cost, and
            // it is per tail call rather than per call.
            const scope = self.scopes.items[i];
            for (scope.captured) |b| {
                self.defineIn(base, b.name, b.val);
            }
            for (scope.bindings.items) |b| {
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
        // Only the current callee's own region is searched for an existing
        // binding. Reaching below `own_base` would update an entry a previous
        // callee left in this frame, and it would stay at that low index --
        // where `lookup` reads it only *after* the captures, so the callee's
        // own parameter would lose to something it captured.
        for (scope.bindings.items[scope.own_base..]) |*binding| {
            if (std.mem.eql(u8, binding.name, name)) {
                binding.val = value;
                return;
            }
        }
        scope.bindings.append(self.allocator, .{ .name = name, .val = value }) catch {};
    }

    /// Return all bindings visible from the current scope (innermost wins).
    /// `seen` is a hash set rather than a list that is searched.
    ///
    /// Every `def` and every `fn` literal snapshots the visible environment
    /// through here, and with the ~400-definition prelude in the file the
    /// linear search made one `fn(x) do x end` cost 3ms.
    pub fn allBindings(self: *const Environment, allocator: std.mem.Allocator) []const Binding {
        var seen: std.StringHashMapUnmanaged(void) = .{};
        var result = std.ArrayList(Binding){ .items = &.{}, .capacity = 0 };

        // Walk from innermost to outermost
        var i: usize = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            const scope = self.scopes.items[i];
            // `seen` keeps the first of a name, so these are walked in the
            // order `lookup` resolves them: the callee's own bindings, then
            // what it captured, then what an earlier callee left behind.
            for (scope.bindings.items[scope.own_base..]) |binding| {
                const got = seen.getOrPut(allocator, binding.name) catch continue;
                if (!got.found_existing) {
                    result.append(allocator, binding) catch {};
                }
            }
            for (scope.captured) |binding| {
                const got = seen.getOrPut(allocator, binding.name) catch continue;
                if (!got.found_existing) {
                    result.append(allocator, .{ .name = binding.name, .val = binding.val }) catch {};
                }
            }
            for (scope.bindings.items[0..scope.own_base]) |binding| {
                const got = seen.getOrPut(allocator, binding.name) catch continue;
                if (!got.found_existing) {
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
            // Three tiers, in the order copying the captures in used to
            // produce: what the current callee bound, then what it captured,
            // then what an earlier callee left in a reused frame.
            if (scope.names & bit != 0) {
                var j: usize = scope.bindings.items.len;
                while (j > scope.own_base) {
                    j -= 1;
                    if (std.mem.eql(u8, scope.bindings.items[j].name, name)) {
                        return scope.bindings.items[j].val;
                    }
                }
            }
            if (scope.captured_names & bit != 0) {
                var k: usize = scope.captured.len;
                while (k > 0) {
                    k -= 1;
                    if (std.mem.eql(u8, scope.captured[k].name, name)) {
                        return scope.captured[k].val;
                    }
                }
            }
            if (scope.names & bit != 0) {
                var j: usize = scope.own_base;
                while (j > 0) {
                    j -= 1;
                    if (std.mem.eql(u8, scope.bindings.items[j].name, name)) {
                        return scope.bindings.items[j].val;
                    }
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

test "a call does not pay for what the closure captured" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Environment.init(alloc);
    const val = try alloc.create(Value);
    val.* = Value{ .integer = 7 };

    // A closure that captured four hundred names, which is the shape every
    // translated Temper program has: the prelude defines that many and each
    // definition captures all of them.
    var captured = try alloc.alloc(Value.CapturedBinding, 400);
    var names: u64 = 0;
    for (0..400) |i| {
        const name = try std.fmt.allocPrint(alloc, "prelude_helper_{d}", .{i});
        captured[i] = .{ .name = name, .val = val };
        names |= Environment.nameBit(name);
    }

    env.pushScope();
    env.lendCaptured(captured, names);
    // Lending is what a call does. Nothing was written into the scope, so the
    // cost does not grow with how much was captured.
    try std.testing.expectEqual(@as(usize, 0), env.scopes.items[env.scopes.items.len - 1].bindings.items.len);
    try std.testing.expect(env.lookup("prelude_helper_399") != null);
    try std.testing.expect(env.lookup("prelude_helper_0") != null);
    try std.testing.expect(env.lookup("never_defined") == null);
}

test "a parameter shadows a capture of the same name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Environment.init(alloc);
    const captured_val = try alloc.create(Value);
    captured_val.* = Value{ .integer = 1 };
    const param_val = try alloc.create(Value);
    param_val.* = Value{ .integer = 2 };

    const captured = try alloc.alloc(Value.CapturedBinding, 1);
    captured[0] = .{ .name = "x", .val = captured_val };

    env.pushScope();
    env.lendCaptured(captured, Environment.nameBit("x"));
    try std.testing.expect(env.lookup("x").?.eql(Value{ .integer = 1 }));
    // A call lends the captures and then binds its parameters, so the
    // parameter has to win -- which it does because lookup reads `bindings`
    // before `captured`.
    env.define("x", param_val);
    try std.testing.expect(env.lookup("x").?.eql(Value{ .integer = 2 }));
}

test "collapsing a scope keeps what it was lent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Environment.init(alloc);
    const val = try alloc.create(Value);
    val.* = Value{ .integer = 42 };
    const captured = try alloc.alloc(Value.CapturedBinding, 1);
    captured[0] = .{ .name = "helper", .val = val };

    const base = env.depth();
    env.pushScope();
    env.lendCaptured(captured, Environment.nameBit("helper"));
    env.pushScope();
    // A tail call collapses the frames it is leaving. A capture that only the
    // collapsed scope was lent has to survive, or the callee cannot see what
    // its caller could.
    env.collapseTo(base);
    try std.testing.expect(env.lookup("helper") != null);
}

test "a callee's capture beats what an earlier callee left in the frame" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Environment.init(alloc);
    const stale = try alloc.create(Value);
    stale.* = Value{ .integer = 1 };
    const mine = try alloc.create(Value);
    mine.* = Value{ .integer = 2 };

    const first = try alloc.alloc(Value.CapturedBinding, 1);
    first[0] = .{ .name = "other", .val = stale };
    const second = try alloc.alloc(Value.CapturedBinding, 1);
    second[0] = .{ .name = "k", .val = mine };

    env.pushScope();
    // One callee runs in the frame and binds `k`...
    env.lendCaptured(first, Environment.nameBit("other"));
    env.define("k", stale);
    // ...then tail-calls another, which captured its own `k`. The one left
    // behind must not shadow it. This is the regex engine's continuation:
    // when it did, `temper_rx_seq_at` ran off the end of its node list and
    // kept calling itself, because the `k` it reached was the wrong one.
    env.lendCaptured(second, Environment.nameBit("k"));
    try std.testing.expect(env.lookup("k").?.eql(Value{ .integer = 2 }));
    // What the outgoing callee captured is still reachable, below both.
    try std.testing.expect(env.lookup("other") != null);
}

test "the same closure re-entering its frame does not grow it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = Environment.init(alloc);
    const val = try alloc.create(Value);
    val.* = Value{ .integer = 5 };
    const captured = try alloc.alloc(Value.CapturedBinding, 1);
    captured[0] = .{ .name = "g", .val = val };

    env.pushScope();
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        // What a tail-recursive loop does: lend the same captures, bind the
        // same parameter names again.
        env.lendCaptured(captured, Environment.nameBit("g"));
        env.define("n", val);
        env.define("acc", val);
    }
    const scope = env.scopes.items[env.scopes.items.len - 1];
    try std.testing.expectEqual(@as(usize, 2), scope.bindings.items.len);
}
