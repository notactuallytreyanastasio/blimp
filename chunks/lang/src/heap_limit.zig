//! A ceiling on what a run may allocate.
//!
//! The evaluator does not reclaim values inside a run (see gc.zig), so a
//! program that allocates in a loop grows for as long as it runs.  Without a
//! ceiling the end of that story is the machine, not the program: a `fib(40)`
//! once reached about 100 GB before anyone could read the output.
//!
//! This wraps the allocator the arena draws from, so `used` is the memory the
//! process actually took, not the sum of the evaluator's small requests.  Past
//! the limit every allocation fails, which surfaces as a normal
//! `error.OutOfMemory` the evaluator already knows how to unwind — and `hit`
//! tells the caller to explain what happened rather than blame the machine.

const std = @import("std");

pub const HeapLimit = struct {
    child: std.mem.Allocator,
    /// Bytes this run may hold at once.  Zero means no ceiling.
    limit: usize,
    used: usize = 0,
    /// Set the first time the limit refuses an allocation.
    hit: bool = false,

    pub const default_bytes: usize = 2 * 1024 * 1024 * 1024;

    /// The ceiling for this run: `BLIMP_HEAP_LIMIT` in bytes, or the default.
    /// `BLIMP_HEAP_LIMIT=0` lifts it.
    ///
    /// The environment arrives as a capability rather than being read from a
    /// global, because zig 0.16 removed `std.process.getEnvVarOwned`.
    pub fn fromEnv(child: std.mem.Allocator, environ: std.process.Environ) HeapLimit {
        const text = environ.getPosix("BLIMP_HEAP_LIMIT") orelse
            return .{ .child = child, .limit = default_bytes };
        const parsed = std.fmt.parseInt(usize, std.mem.trim(u8, text, " "), 10) catch
            return .{ .child = child, .limit = default_bytes };
        return .{ .child = child, .limit = parsed };
    }

    pub fn allocator(self: *HeapLimit) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn room(self: *HeapLimit, extra: usize) bool {
        if (self.limit == 0) return true;
        if (self.used + extra <= self.limit) return true;
        self.hit = true;
        return false;
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *HeapLimit = @ptrCast(@alignCast(ctx));
        if (!self.room(len)) return null;
        const p = self.child.rawAlloc(len, alignment, ra) orelse return null;
        self.used += len;
        return p;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *HeapLimit = @ptrCast(@alignCast(ctx));
        if (new_len > memory.len and !self.room(new_len - memory.len)) return false;
        if (!self.child.rawResize(memory, alignment, new_len, ra)) return false;
        self.used = self.used + new_len - memory.len;
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *HeapLimit = @ptrCast(@alignCast(ctx));
        if (new_len > memory.len and !self.room(new_len - memory.len)) return null;
        const p = self.child.rawRemap(memory, alignment, new_len, ra) orelse return null;
        self.used = self.used + new_len - memory.len;
        return p;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *HeapLimit = @ptrCast(@alignCast(ctx));
        self.child.rawFree(memory, alignment, ra);
        self.used -= memory.len;
    }

    /// What to tell someone whose program ran into the ceiling.
    pub fn report(self: *const HeapLimit) void {
        std.debug.print(
            \\
            \\Out of heap: this run reached its {d} MB ceiling.
            \\
            \\The interpreter does not reclaim values while a program runs, so a
            \\long loop or a deep recursion grows until it stops.  Raise the
            \\ceiling with BLIMP_HEAP_LIMIT=<bytes>, or 0 to remove it.
            \\
        , .{self.limit / (1024 * 1024)});
    }
};

test "allocation past the ceiling fails instead of growing" {
    var limit = HeapLimit{ .child = std.testing.allocator, .limit = 4096 };
    const alloc = limit.allocator();

    const first = try alloc.alloc(u8, 2048);
    try std.testing.expectEqual(@as(usize, 2048), limit.used);
    try std.testing.expect(!limit.hit);

    try std.testing.expectError(error.OutOfMemory, alloc.alloc(u8, 4096));
    try std.testing.expect(limit.hit);

    // The refusal costs nothing: what was already taken is still usable, and
    // giving it back makes room again.
    alloc.free(first);
    try std.testing.expectEqual(@as(usize, 0), limit.used);
    const second = try alloc.alloc(u8, 4096);
    alloc.free(second);
}

test "a zero limit is no limit" {
    var limit = HeapLimit{ .child = std.testing.allocator, .limit = 0 };
    const alloc = limit.allocator();
    const big = try alloc.alloc(u8, 1024 * 1024);
    defer alloc.free(big);
    try std.testing.expect(!limit.hit);
}

test "an arena on a ceiling stops growing at it" {
    var limit = HeapLimit{ .child = std.testing.allocator, .limit = 1 << 20 };
    var arena = std.heap.ArenaAllocator.init(limit.allocator());
    defer arena.deinit();

    var taken: usize = 0;
    while (arena.allocator().alloc(u8, 4096)) |_| {
        taken += 4096;
        if (taken > 8 << 20) break; // would mean the ceiling did nothing
    } else |err| {
        try std.testing.expectEqual(error.OutOfMemory, err);
    }
    try std.testing.expect(limit.hit);
    try std.testing.expect(limit.used <= limit.limit);
}
