//! Mutable buffers the evaluator's immutable values cannot be: a growing list,
//! a growing string, and an insertion-ordered hash map, each held in a table
//! here and named by an Int handle (the way sqlite_* names a database).
//!
//! Why: Temper's ListBuilder, StringBuilder and Map compile to actors, and an
//! actor's state is a Value. A Value is immutable and the evaluator frees
//! nothing, so `append(items, x)` copies the whole list and the old copy lives
//! for ever: 20,000 adds were 1.8 GB. Here the element array is one geometrically
//! growing allocation owned by libc's allocator, so an add is amortised O(1)
//! and the old array is freed on growth.
//!
//!   buf_new() -> Int                       sbuf_new() -> Int
//!   buf_push(h, v) -> nil                  sbuf_append(h, s) -> nil
//!   buf_len(h) -> Int                      sbuf_len(h) -> Int   (bytes)
//!   buf_get(h, i) -> v | nil past the end  sbuf_string(h) -> String
//!   buf_set(h, i, v) -> nil                sbuf_clear(h) -> nil
//!   buf_pop(h) -> v
//!   buf_items(h) -> List (a snapshot)
//!   buf_replace(h, list) -> nil            buf_extend(h, list) -> nil
//!   buf_clear(h) -> nil
//!
//!   hmap_new() -> Int
//!   hmap_get(h, key, default) -> v | default     hmap_has(h, key) -> Bool
//!   hmap_put(h, key, v) -> nil                   hmap_remove(h, key, default) -> old | default
//!   hmap_len(h) -> Int                           hmap_clear(h) -> nil
//!   hmap_keys(h) / hmap_values(h) -> List        hmap_entries(h) -> [[k, v], ...]
//!   hmap_assign(h, src) -> nil   (h becomes a copy of src)
//!
//! Map keys are compared through a canonical encoding, so lookups are O(1) on
//! average, and equal exactly when Value.eql says so: String, Int, Float,
//! Atom, Bool, nil, actor refs, and lists/tuples of those. A key outside that
//! (a map, a closure, a view node) is a TypeError, not a silent miss.
//! Iteration is in insertion order; setting an existing key keeps its place.
//!
//! The snapshots (buf_items, sbuf_string, hmap_keys/values/entries) are cached
//! until the next mutation, so reading a buffer that is not changing costs O(1)
//! after the first read, and a loop that alternates a write and a read costs
//! O(n) per pair (what it cost before, not more).
//!
//! The values a buffer holds are pointers into the evaluator's heap. gc.compact
//! moves that heap, and carries what the buffers point at through
//! `valuePointers` and `relocate` (docs/lang_design/handles.md); `inUse` is
//! what the REPL and --serve check. fork() copies the table with the rest of the process, which is
//! what is wanted. Handles are never reused or closed: a builder lives as long
//! as the process, like every actor. Single-threaded: only the evaluator
//! touches the table. Native only (builtins.zig stubs these on WASM).

const std = @import("std");
const builtins = @import("builtins.zig");
const Value = @import("value.zig").Value;
const EvalError = builtins.EvalError;

const gpa = std.heap.c_allocator;

const ListBuf = struct {
    items: std.ArrayList(*const Value) = .empty,
    snap: ?*const Value = null,
};

const StrBuf = struct {
    bytes: std.ArrayList(u8) = .empty,
    snap: ?*const Value = null,
};

const Slot = struct {
    key: *const Value,
    val: *const Value,
    /// The canonical encoding; owned, and the same bytes the index is keyed by.
    ckey: []u8,
    live: bool,
};

const HMap = struct {
    slots: std.ArrayList(Slot) = .empty,
    index: std.StringHashMapUnmanaged(u32) = .empty,
    live: u32 = 0,
    keys_snap: ?*const Value = null,
    values_snap: ?*const Value = null,
    entries_snap: ?*const Value = null,

    fn dirty(self: *HMap) void {
        self.keys_snap = null;
        self.values_snap = null;
        self.entries_snap = null;
    }
};

const Obj = union(enum) { list: ListBuf, str: StrBuf, map: HMap };

var table: std.ArrayList(Obj) = .empty;
var scratch: std.ArrayList(u8) = .empty;

/// True once any buffer exists.
pub fn inUse() bool {
    return table.items.len > 0;
}

/// Empty the table and free what it owned.  For tests, and only tests: a
/// program's buffers live as long as the process.  The table is
/// process-global, so a test that made buffers and then freed the arena
/// their values live in leaves pointers behind, and the next test that
/// compacts follows them into freed memory ("switch on corrupt value" in
/// gc.Copier.value, from the handles tests into the gc test).  Every test
/// that makes a buffer defers this.
pub fn dropAll() void {
    for (table.items) |*o| switch (o.*) {
        .list => |*b| b.items.deinit(gpa),
        .str => |*b| b.bytes.deinit(gpa),
        .map => |*m| {
            clearMap(m);
            m.slots.deinit(gpa);
            m.index.deinit(gpa);
        },
    };
    table.clearAndFree(gpa);
}

/// Every pointer into the value heap that a buffer or a map holds, in a
/// fixed order, so a compaction can copy what they point at.  `relocate`
/// takes the copies back in the same order.  Nothing may touch the tables
/// in between; a compaction runs with nothing else happening.
pub fn valuePointers(allocator: std.mem.Allocator) error{OutOfMemory}![]*const Value {
    var out: std.ArrayList(*const Value) = .empty;
    for (table.items) |*o| switch (o.*) {
        .list => |*b| {
            for (b.items.items) |v| try out.append(allocator, v);
            if (b.snap) |s| try out.append(allocator, s);
        },
        .str => |*b| {
            if (b.snap) |s| try out.append(allocator, s);
        },
        .map => |*m| {
            for (m.slots.items) |slot| {
                try out.append(allocator, slot.key);
                try out.append(allocator, slot.val);
            }
            if (m.keys_snap) |s| try out.append(allocator, s);
            if (m.values_snap) |s| try out.append(allocator, s);
            if (m.entries_snap) |s| try out.append(allocator, s);
        },
    };
    return out.toOwnedSlice(allocator);
}

/// Write the copies `valuePointers` listed back into the tables.
pub fn relocate(moved: []const *const Value) void {
    var i: usize = 0;
    for (table.items) |*o| switch (o.*) {
        .list => |*b| {
            for (b.items.items) |*v| {
                v.* = moved[i];
                i += 1;
            }
            if (b.snap != null) {
                b.snap = moved[i];
                i += 1;
            }
        },
        .str => |*b| {
            if (b.snap != null) {
                b.snap = moved[i];
                i += 1;
            }
        },
        .map => |*m| {
            for (m.slots.items) |*slot| {
                slot.key = moved[i];
                slot.val = moved[i + 1];
                i += 2;
            }
            if (m.keys_snap != null) {
                m.keys_snap = moved[i];
                i += 1;
            }
            if (m.values_snap != null) {
                m.values_snap = moved[i];
                i += 1;
            }
            if (m.entries_snap != null) {
                m.entries_snap = moved[i];
                i += 1;
            }
        },
    };
    std.debug.assert(i == moved.len);
}

fn box(allocator: std.mem.Allocator, v: Value) EvalError!*const Value {
    if (@import("value.zig").interned.get(v)) |shared| return shared;
    const p = allocator.create(Value) catch return error.OutOfMemory;
    p.* = v;
    return p;
}

fn create(o: Obj, allocator: std.mem.Allocator) EvalError!*const Value {
    table.append(gpa, o) catch return error.OutOfMemory;
    return box(allocator, .{ .integer = @intCast(table.items.len) });
}

fn obj(v: *const Value, comptime field: []const u8, name: []const u8) EvalError!*@FieldType(Obj, field) {
    if (v.* != .integer or v.integer < 1 or v.integer > table.items.len)
        return builtins.failArg("{s}: {d} is not a handle", .{ name, if (v.* == .integer) v.integer else 0 });
    const o = &table.items[@intCast(v.integer - 1)];
    if (o.* != @field(std.meta.Tag(Obj), field)) return builtins.failArg("{s}: handle {d} is a different kind of buffer", .{ name, v.integer });
    return &@field(o.*, field);
}

fn listValue(allocator: std.mem.Allocator, items: []const *const Value) EvalError!*const Value {
    const copy = allocator.dupe(*const Value, items) catch return error.OutOfMemory;
    return box(allocator, .{ .list = copy });
}

// ── lists ───────────────────────────────────────────────────

pub fn bufNew(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 0) return error.TypeError;
    return create(.{ .list = .{} }, allocator);
}

pub fn bufPush(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 2) return error.TypeError;
    const b = try obj(args[0], "list", "buf_push");
    b.items.append(gpa, args[1]) catch return error.OutOfMemory;
    b.snap = null;
    return box(allocator, .nil);
}

pub fn bufLen(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1) return error.TypeError;
    const b = try obj(args[0], "list", "buf_len");
    return box(allocator, .{ .integer = @intCast(b.items.items.len) });
}

pub fn bufGet(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 2 or args[1].* != .integer) return error.TypeError;
    const b = try obj(args[0], "list", "buf_get");
    const i = args[1].integer;
    if (i < 0 or i >= b.items.items.len) return box(allocator, .nil);
    return b.items.items[@intCast(i)];
}

pub fn bufSet(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 3 or args[1].* != .integer) return error.TypeError;
    const b = try obj(args[0], "list", "buf_set");
    const i = args[1].integer;
    if (i < 0 or i >= b.items.items.len) return error.TypeError;
    b.items.items[@intCast(i)] = args[2];
    b.snap = null;
    return box(allocator, .nil);
}

pub fn bufPop(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    _ = allocator;
    if (args.len != 1) return error.TypeError;
    const b = try obj(args[0], "list", "buf_pop");
    if (b.items.items.len == 0) return error.TypeError;
    b.snap = null;
    return b.items.pop().?;
}

pub fn bufItems(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1) return error.TypeError;
    const b = try obj(args[0], "list", "buf_items");
    if (b.snap) |s| return s;
    const s = try listValue(allocator, b.items.items);
    b.snap = s;
    return s;
}

pub fn bufReplace(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 2 or args[1].* != .list) return error.TypeError;
    const b = try obj(args[0], "list", "buf_replace");
    const src = args[1].list;
    b.items.clearRetainingCapacity();
    b.items.appendSlice(gpa, src) catch return error.OutOfMemory;
    // The list handed in is immutable, so it is the snapshot.
    b.snap = args[1];
    return box(allocator, .nil);
}

pub fn bufExtend(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 2 or args[1].* != .list) return error.TypeError;
    const b = try obj(args[0], "list", "buf_extend");
    b.items.appendSlice(gpa, args[1].list) catch return error.OutOfMemory;
    b.snap = null;
    return box(allocator, .nil);
}

pub fn bufClear(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1) return error.TypeError;
    const b = try obj(args[0], "list", "buf_clear");
    b.items.clearRetainingCapacity();
    b.snap = null;
    return box(allocator, .nil);
}

// ── strings ─────────────────────────────────────────────────

pub fn sbufNew(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 0) return error.TypeError;
    return create(.{ .str = .{} }, allocator);
}

pub fn sbufAppend(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 2 or args[1].* != .string) return error.TypeError;
    const b = try obj(args[0], "str", "sbuf_append");
    b.bytes.appendSlice(gpa, args[1].string) catch return error.OutOfMemory;
    b.snap = null;
    return box(allocator, .nil);
}

pub fn sbufLen(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1) return error.TypeError;
    const b = try obj(args[0], "str", "sbuf_len");
    return box(allocator, .{ .integer = @intCast(b.bytes.items.len) });
}

pub fn sbufString(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1) return error.TypeError;
    const b = try obj(args[0], "str", "sbuf_string");
    if (b.snap) |s| return s;
    const copy = allocator.dupe(u8, b.bytes.items) catch return error.OutOfMemory;
    const s = try box(allocator, .{ .string = copy });
    b.snap = s;
    return s;
}

pub fn sbufClear(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1) return error.TypeError;
    const b = try obj(args[0], "str", "sbuf_clear");
    b.bytes.clearRetainingCapacity();
    b.snap = null;
    return box(allocator, .nil);
}

// ── maps ────────────────────────────────────────────────────

/// Every encoding is self-delimiting, so a list of keys cannot collide with
/// another list, and a type prefix keeps Int 1 apart from String "1".
fn encode(out: *std.ArrayList(u8), v: *const Value) EvalError!void {
    switch (v.*) {
        .integer => |n| out.print(gpa, "i{d};", .{n}) catch return error.OutOfMemory,
        .string => |s| {
            out.print(gpa, "s{d}:", .{s.len}) catch return error.OutOfMemory;
            out.appendSlice(gpa, s) catch return error.OutOfMemory;
        },
        .float => |f| {
            // 0.0 == -0.0 under Value.eql, so they share an encoding.
            const bits: u64 = if (f == 0) 0 else @bitCast(f);
            out.print(gpa, "f{x};", .{bits}) catch return error.OutOfMemory;
        },
        .atom => |s| {
            out.print(gpa, "a{d}:", .{s.len}) catch return error.OutOfMemory;
            out.appendSlice(gpa, s) catch return error.OutOfMemory;
        },
        .boolean => |b| out.appendSlice(gpa, if (b) "b1" else "b0") catch return error.OutOfMemory,
        .nil => out.append(gpa, 'n') catch return error.OutOfMemory,
        .actor_ref => |r| out.print(gpa, "r{d};", .{r.id}) catch return error.OutOfMemory,
        .list => |items| {
            out.print(gpa, "l{d}[", .{items.len}) catch return error.OutOfMemory;
            for (items) |x| try encode(out, x);
        },
        .tuple => |items| {
            out.print(gpa, "t{d}[", .{items.len}) catch return error.OutOfMemory;
            for (items) |x| try encode(out, x);
        },
        else => return builtins.failArg("hmap: a {s} cannot be a map key", .{@tagName(v.*)}),
    }
}

fn encodeKey(v: *const Value) EvalError![]const u8 {
    scratch.clearRetainingCapacity();
    try encode(&scratch, v);
    return scratch.items;
}

pub fn hmapNew(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 0) return error.TypeError;
    return create(.{ .map = .{} }, allocator);
}

fn slotOf(m: *HMap, key: *const Value) EvalError!?u32 {
    return m.index.get(try encodeKey(key));
}

pub fn hmapGet(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    _ = allocator;
    if (args.len != 3) return error.TypeError;
    const m = try obj(args[0], "map", "hmap_get");
    const i = (try slotOf(m, args[1])) orelse return args[2];
    return m.slots.items[i].val;
}

pub fn hmapHas(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 2) return error.TypeError;
    const m = try obj(args[0], "map", "hmap_has");
    return box(allocator, .{ .boolean = (try slotOf(m, args[1])) != null });
}

pub fn hmapPut(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 3) return error.TypeError;
    const m = try obj(args[0], "map", "hmap_put");
    const ck = try encodeKey(args[1]);
    const gop = m.index.getOrPut(gpa, ck) catch return error.OutOfMemory;
    if (gop.found_existing) {
        m.slots.items[gop.value_ptr.*].val = args[2];
    } else {
        const owned = gpa.dupe(u8, ck) catch {
            _ = m.index.remove(ck);
            return error.OutOfMemory;
        };
        gop.key_ptr.* = owned;
        gop.value_ptr.* = @intCast(m.slots.items.len);
        m.slots.append(gpa, .{ .key = args[1], .val = args[2], .ckey = owned, .live = true }) catch return error.OutOfMemory;
        m.live += 1;
    }
    m.dirty();
    return box(allocator, .nil);
}

pub fn hmapRemove(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    _ = allocator;
    if (args.len != 3) return error.TypeError;
    const m = try obj(args[0], "map", "hmap_remove");
    const ck = try encodeKey(args[1]);
    const kv = m.index.fetchRemove(ck) orelse return args[2];
    const slot = &m.slots.items[kv.value];
    const old = slot.val;
    slot.live = false;
    gpa.free(slot.ckey);
    m.live -= 1;
    m.dirty();
    // Tombstones are swept once they outnumber the live entries.
    if (m.slots.items.len > 32 and m.slots.items.len > 2 * m.live) sweep(m);
    return old;
}

fn sweep(m: *HMap) void {
    var out: usize = 0;
    for (m.slots.items) |s| {
        if (!s.live) continue;
        m.slots.items[out] = s;
        m.index.getPtr(s.ckey).?.* = @intCast(out);
        out += 1;
    }
    m.slots.shrinkRetainingCapacity(out);
}

pub fn hmapLen(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1) return error.TypeError;
    const m = try obj(args[0], "map", "hmap_len");
    return box(allocator, .{ .integer = m.live });
}

fn clearMap(m: *HMap) void {
    for (m.slots.items) |s| if (s.live) gpa.free(s.ckey);
    m.slots.clearRetainingCapacity();
    m.index.clearRetainingCapacity();
    m.live = 0;
    m.dirty();
}

pub fn hmapClear(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1) return error.TypeError;
    clearMap(try obj(args[0], "map", "hmap_clear"));
    return box(allocator, .nil);
}

const Part = enum { keys, values, entries };

fn part(allocator: std.mem.Allocator, args: []const *const Value, which: Part, name: []const u8) EvalError!*const Value {
    if (args.len != 1) return error.TypeError;
    const m = try obj(args[0], "map", name);
    const cached = switch (which) {
        .keys => m.keys_snap,
        .values => m.values_snap,
        .entries => m.entries_snap,
    };
    if (cached) |c| return c;
    const out = allocator.alloc(*const Value, m.live) catch return error.OutOfMemory;
    var n: usize = 0;
    for (m.slots.items) |s| {
        if (!s.live) continue;
        out[n] = switch (which) {
            .keys => s.key,
            .values => s.val,
            .entries => try listValue(allocator, &.{ s.key, s.val }),
        };
        n += 1;
    }
    const v = try box(allocator, .{ .list = out });
    switch (which) {
        .keys => m.keys_snap = v,
        .values => m.values_snap = v,
        .entries => m.entries_snap = v,
    }
    return v;
}

pub fn hmapKeys(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    return part(allocator, args, .keys, "hmap_keys");
}
pub fn hmapValues(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    return part(allocator, args, .values, "hmap_values");
}
pub fn hmapEntries(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    return part(allocator, args, .entries, "hmap_entries");
}

pub fn hmapAssign(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 2) return error.TypeError;
    const dst_i = args[0];
    const src_i = args[1];
    _ = try obj(dst_i, "map", "hmap_assign");
    _ = try obj(src_i, "map", "hmap_assign");
    if (dst_i.integer == src_i.integer) return box(allocator, .nil);
    // Neither pointer is held across a call that grows the table.
    const src = &table.items[@intCast(src_i.integer - 1)].map;
    const dst = &table.items[@intCast(dst_i.integer - 1)].map;
    clearMap(dst);
    for (src.slots.items) |s| {
        if (!s.live) continue;
        const owned = gpa.dupe(u8, s.ckey) catch return error.OutOfMemory;
        dst.index.put(gpa, owned, @intCast(dst.slots.items.len)) catch return error.OutOfMemory;
        dst.slots.append(gpa, .{ .key = s.key, .val = s.val, .ckey = owned, .live = true }) catch return error.OutOfMemory;
        dst.live += 1;
    }
    return box(allocator, .nil);
}

// ── tests ───────────────────────────────────────────────────

fn sv(a: std.mem.Allocator, s: []const u8) !*const Value {
    return box(a, .{ .string = s });
}
fn iv(a: std.mem.Allocator, n: i64) !*const Value {
    return box(a, .{ .integer = n });
}

test "buf_push, get, set, pop, items, replace, clear" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    defer dropAll();
    const h = try bufNew(a, &.{});
    for (0..100) |i| _ = try bufPush(a, &.{ h, try iv(a, @intCast(i * 1000)) });
    try std.testing.expectEqual(@as(i64, 100), (try bufLen(a, &.{h})).integer);
    try std.testing.expectEqual(@as(i64, 7000), (try bufGet(a, &.{ h, try iv(a, 7) })).integer);
    try std.testing.expect((try bufGet(a, &.{ h, try iv(a, 100) })).* == .nil);
    _ = try bufSet(a, &.{ h, try iv(a, 0), try sv(a, "x") });
    const snap = try bufItems(a, &.{h});
    try std.testing.expectEqualStrings("x", snap.list[0].string);
    try std.testing.expectEqual(snap, try bufItems(a, &.{h})); // cached
    _ = try bufPush(a, &.{ h, try iv(a, 1) });
    try std.testing.expectEqual(@as(usize, 100), snap.list.len); // the old snapshot did not change
    try std.testing.expectEqual(@as(usize, 101), (try bufItems(a, &.{h})).list.len);
    try std.testing.expectEqual(@as(i64, 1), (try bufPop(a, &.{h})).integer);
    try std.testing.expectError(error.TypeError, bufSet(a, &.{ h, try iv(a, 100), try iv(a, 1) }));
    _ = try bufExtend(a, &.{ h, snap });
    try std.testing.expectEqual(@as(i64, 200), (try bufLen(a, &.{h})).integer);
    _ = try bufReplace(a, &.{ h, snap });
    try std.testing.expectEqual(@as(i64, 100), (try bufLen(a, &.{h})).integer);
    _ = try bufClear(a, &.{h});
    try std.testing.expectError(error.TypeError, bufPop(a, &.{h}));
    try std.testing.expectError(error.TypeError, bufLen(a, &.{ try iv(a, 9999) }));
    const s = try sbufNew(a, &.{});
    try std.testing.expectError(error.TypeError, bufLen(a, &.{s})); // wrong kind
}

test "sbuf appends bytes and snapshots" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    defer dropAll();
    const h = try sbufNew(a, &.{});
    for (0..20000) |_| _ = try sbufAppend(a, &.{ h, try sv(a, "0123456789") });
    try std.testing.expectEqual(@as(i64, 200000), (try sbufLen(a, &.{h})).integer);
    const s = try sbufString(a, &.{h});
    try std.testing.expectEqual(@as(usize, 200000), s.string.len);
    try std.testing.expectEqual(s, try sbufString(a, &.{h}));
    _ = try sbufAppend(a, &.{ h, try sv(a, "é") });
    try std.testing.expectEqual(@as(i64, 200002), (try sbufLen(a, &.{h})).integer);
    _ = try sbufClear(a, &.{h});
    try std.testing.expectEqualStrings("", (try sbufString(a, &.{h})).string);
}

test "hmap keeps Int 1 and String \"1\" apart, in insertion order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    defer dropAll();
    const none = try box(a, .{ .atom = "none" });
    const h = try hmapNew(a, &.{});
    _ = try hmapPut(a, &.{ h, try sv(a, "1"), try iv(a, 10) });
    _ = try hmapPut(a, &.{ h, try iv(a, 1), try iv(a, 20) });
    _ = try hmapPut(a, &.{ h, try sv(a, "b"), try iv(a, 30) });
    _ = try hmapPut(a, &.{ h, try sv(a, "1"), try iv(a, 11) }); // replaces, keeps its place
    try std.testing.expectEqual(@as(i64, 3), (try hmapLen(a, &.{h})).integer);
    try std.testing.expectEqual(@as(i64, 11), (try hmapGet(a, &.{ h, try sv(a, "1"), none })).integer);
    try std.testing.expectEqual(@as(i64, 20), (try hmapGet(a, &.{ h, try iv(a, 1), none })).integer);
    try std.testing.expect((try hmapGet(a, &.{ h, try sv(a, "zz"), none })) == none);
    const keys = try hmapKeys(a, &.{h});
    try std.testing.expectEqualStrings("1", keys.list[0].string);
    try std.testing.expectEqual(@as(i64, 1), keys.list[1].integer);
    try std.testing.expectEqualStrings("b", keys.list[2].string);
    const es = try hmapEntries(a, &.{h});
    try std.testing.expectEqual(@as(i64, 30), es.list[2].list[1].integer);
    // list keys are structural and self-delimiting
    const k1 = try box(a, .{ .list = &.{ try sv(a, "a"), try sv(a, "bc") } });
    const k2 = try box(a, .{ .list = &.{ try sv(a, "ab"), try sv(a, "c") } });
    _ = try hmapPut(a, &.{ h, k1, try iv(a, 1) });
    try std.testing.expect((try hmapHas(a, &.{ h, k1 })).boolean);
    try std.testing.expect(!(try hmapHas(a, &.{ h, k2 })).boolean);
    const clo = try box(a, .{ .map = &.{} });
    try std.testing.expectError(error.TypeError, hmapHas(a, &.{ h, clo }));
}

test "hmap remove, sweep and assign" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    defer dropAll();
    const none = try box(a, .{ .atom = "none" });
    const h = try hmapNew(a, &.{});
    var buf: [16]u8 = undefined;
    for (0..1000) |i| {
        const k = try std.fmt.bufPrint(&buf, "k{d}", .{i});
        _ = try hmapPut(a, &.{ h, try sv(a, try a.dupe(u8, k)), try iv(a, @intCast(i)) });
    }
    for (0..990) |i| {
        const k = try std.fmt.bufPrint(&buf, "k{d}", .{i});
        const old = try hmapRemove(a, &.{ h, try sv(a, k), none });
        try std.testing.expectEqual(@as(i64, @intCast(i)), old.integer);
    }
    try std.testing.expect((try hmapRemove(a, &.{ h, try sv(a, "k0"), none })) == none);
    try std.testing.expectEqual(@as(i64, 10), (try hmapLen(a, &.{h})).integer);
    const keys = try hmapKeys(a, &.{h});
    try std.testing.expectEqualStrings("k990", keys.list[0].string);
    try std.testing.expectEqualStrings("k999", keys.list[9].string);
    try std.testing.expectEqual(@as(i64, 995), (try hmapGet(a, &.{ h, try sv(a, "k995"), none })).integer);
    const g = try hmapNew(a, &.{});
    _ = try hmapPut(a, &.{ g, try sv(a, "gone"), try iv(a, 1) });
    _ = try hmapAssign(a, &.{ g, h });
    try std.testing.expectEqual(@as(i64, 10), (try hmapLen(a, &.{g})).integer);
    try std.testing.expect(!(try hmapHas(a, &.{ g, try sv(a, "gone") })).boolean);
    _ = try hmapPut(a, &.{ g, try sv(a, "k990"), try iv(a, -1) });
    try std.testing.expectEqual(@as(i64, 990), (try hmapGet(a, &.{ h, try sv(a, "k990"), none })).integer); // copy, not alias
    _ = try hmapClear(a, &.{h});
    try std.testing.expectEqual(@as(i64, 0), (try hmapLen(a, &.{h})).integer);
}
