//! The two numbers a scope lookup wants of a name, computed once.
//!
//! `Environment.lookup` and `defineIn` need `hashName(name)` and
//! `nameBit(name)`.  Computing them from the string on every read hashed a
//! parameter's name once per loop iteration.  The parser computes them once
//! per node and carries them in a `Key`; a node built by hand has the empty
//! key (`bit == 0`, which `nameBit` never returns) and the evaluator hashes
//! for it as before.

/// FNV-1a over the name's bytes.
pub fn hashName(name: []const u8) u32 {
    var h: u32 = 0x811c9dc5;
    for (name) |c| {
        h ^= c;
        h *%= 0x01000193;
    }
    return h;
}

/// The bit a name claims in a scope's `names` mask.  Never zero.
pub fn nameBit(name: []const u8) u64 {
    if (name.len == 0) return 1;
    const first: u64 = name[0];
    const last: u64 = name[name.len - 1];
    const h = first ^ (last << 2) ^ (@as(u64, name.len) << 4);
    return @as(u64, 1) << @as(u6, @truncate(h));
}

pub const Key = struct {
    hash: u32 = 0,
    /// 0 means "not computed".
    bit: u64 = 0,

    pub fn of(name: []const u8) Key {
        return .{ .hash = hashName(name), .bit = nameBit(name) };
    }

    pub fn isSet(self: Key) bool {
        return self.bit != 0;
    }
};

// ------------------------------------------------------------------
// Interning
// ------------------------------------------------------------------

const std = @import("std");

var lock = std.atomic.Value(bool).init(false);
var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
var table: std.StringHashMapUnmanaged(void) = .{};

/// One copy of every name the parser reads, so two occurrences of a name
/// share a pointer and `sameName` can answer with one compare.
///
/// The table is process-wide and never freed: a name is a few bytes, the
/// set of distinct names in a program is small, and a pointer into it is
/// valid for as long as any AST or Binding that holds it, whichever
/// allocator that parse used (`blimp_eval` and the REPL parse with their
/// own, and gc compaction copies Values but never touches these bytes).
/// Several interpreter threads may parse at once, so it is behind a spin
/// lock; it is taken once per identifier token, at parse time only.
pub fn intern(name: []const u8) []const u8 {
    while (lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    defer lock.store(false, .release);
    const got = table.getOrPut(std.heap.page_allocator, name) catch return name;
    if (!got.found_existing) {
        const copy = arena.allocator().dupe(u8, name) catch {
            _ = table.remove(name);
            return name;
        };
        got.key_ptr.* = copy;
        return copy;
    }
    return got.key_ptr.*;
}

/// The intern table's arena, held still until `unlockArena`, so gc
/// compaction can tell a name that lives here (and so outlives every
/// compaction) from bytes it must copy.
pub fn lockArena() *const std.heap.ArenaAllocator {
    while (lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    return &arena;
}

pub fn unlockArena() void {
    lock.store(false, .release);
}

/// Whether two names are the same name.  Interned names answer on the
/// pointer; a name built at run time falls back to the hashes and the
/// bytes.  A pointer match with equal length is equality: the same bytes.
pub inline fn sameName(a: []const u8, a_hash: u32, b: []const u8, b_hash: u32) bool {
    if (a.ptr == b.ptr and a.len == b.len) return true;
    return a_hash == b_hash and std.mem.eql(u8, a, b);
}

test "intern gives one pointer per name, and sameName falls back to bytes" {
    var buf = [_]u8{ 'a', 'b', 'c' };
    const x = intern(&buf);
    const y = intern("abc");
    try std.testing.expect(x.ptr == y.ptr);
    try std.testing.expect(x.ptr != @as([]const u8, &buf).ptr);
    try std.testing.expectEqualStrings("abc", x);
    // A name built at run time: different pointer, same bytes.
    try std.testing.expect(sameName(x, hashName(x), &buf, hashName(&buf)));
    try std.testing.expect(!sameName(x, hashName(x), "abd", hashName("abd")));
    try std.testing.expect(!sameName(x, hashName(x), "ab", hashName("ab")));
}

test "parsed identifiers share a pointer" {
    var arena_a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_a.deinit();
    const Parser = @import("parser.zig").Parser;
    var p = Parser.init(arena_a.allocator(), "foo(foo)\n");
    const nodes = try p.parseFile();
    const call = nodes[0].kind.func_call;
    try std.testing.expect(call.name.ptr == call.args[0].kind.identifier.name.ptr);
}
