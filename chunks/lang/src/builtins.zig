const std = @import("std");
const Value = @import("value.zig").Value;

pub const EvalError = error{
    UndefinedVariable,
    TypeError,
    UnsupportedOperation,
    DivisionByZero,
    NotSupported,
    OutOfMemory,
};

pub const BuiltinFn = *const fn (allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value;

/// Registry entry for a built-in function.
const BuiltinEntry = struct {
    name: []const u8,
    func: BuiltinFn,
};

/// Registry of built-in functions.
/// Uses a simple array list with linear search (same pattern as checker.zig).
pub const BuiltinRegistry = struct {
    entries: std.ArrayList(BuiltinEntry),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) BuiltinRegistry {
        var reg = BuiltinRegistry{
            .entries = .{ .items = &.{}, .capacity = 0 },
            .allocator = allocator,
        };
        reg.register("length", &builtinLength);
        reg.register("max", &builtinMax);
        reg.register("min", &builtinMin);
        reg.register("append", &builtinAppend);
        reg.register("reverse", &builtinReverse);
        reg.register("lookup", &builtinLookup);
        reg.register("put", &builtinPut);
        reg.register("keys", &builtinKeys);
        reg.register("now", &builtinNow);
        return reg;
    }

    fn register(self: *BuiltinRegistry, name: []const u8, func: BuiltinFn) void {
        self.entries.append(self.allocator, .{ .name = name, .func = func }) catch {};
    }

    pub fn get(self: *const BuiltinRegistry, name: []const u8) ?BuiltinFn {
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry.func;
        }
        return null;
    }
};

// ============================================================
// Built-in function implementations
// ============================================================

fn builtinLength(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1) return error.TypeError;
    const arg = args[0];
    switch (arg.*) {
        .list => |items| {
            const result = allocator.create(Value) catch return error.OutOfMemory;
            result.* = Value{ .integer = @intCast(items.len) };
            return result;
        },
        else => return error.TypeError,
    }
}

fn builtinMax(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 2) return error.TypeError;
    switch (args[0].*) {
        .integer => |a| switch (args[1].*) {
            .integer => |b| {
                const result = allocator.create(Value) catch return error.OutOfMemory;
                result.* = Value{ .integer = @max(a, b) };
                return result;
            },
            else => return error.TypeError,
        },
        else => return error.TypeError,
    }
}

fn builtinMin(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 2) return error.TypeError;
    switch (args[0].*) {
        .integer => |a| switch (args[1].*) {
            .integer => |b| {
                const result = allocator.create(Value) catch return error.OutOfMemory;
                result.* = Value{ .integer = @min(a, b) };
                return result;
            },
            else => return error.TypeError,
        },
        else => return error.TypeError,
    }
}

fn builtinAppend(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 2) return error.TypeError;
    switch (args[0].*) {
        .list => |items| {
            const new_items = allocator.alloc(*const Value, items.len + 1) catch return error.OutOfMemory;
            @memcpy(new_items[0..items.len], items);
            new_items[items.len] = args[1];
            const result = allocator.create(Value) catch return error.OutOfMemory;
            result.* = Value{ .list = new_items };
            return result;
        },
        else => return error.TypeError,
    }
}

fn builtinReverse(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1) return error.TypeError;
    switch (args[0].*) {
        .list => |items| {
            const new_items = allocator.alloc(*const Value, items.len) catch return error.OutOfMemory;
            for (items, 0..) |item, i| {
                new_items[items.len - 1 - i] = item;
            }
            const result = allocator.create(Value) catch return error.OutOfMemory;
            result.* = Value{ .list = new_items };
            return result;
        },
        else => return error.TypeError,
    }
}

fn builtinLookup(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 2) return error.TypeError;
    switch (args[0].*) {
        .map => |entries| {
            const key_name = switch (args[1].*) {
                .string => |s| s,
                .atom => |s| s,
                else => return error.TypeError,
            };
            for (entries) |entry| {
                if (std.mem.eql(u8, entry.key, key_name)) {
                    return entry.val;
                }
            }
            // Key not found, return nil
            const result = allocator.create(Value) catch return error.OutOfMemory;
            result.* = .nil;
            return result;
        },
        else => return error.TypeError,
    }
}

fn builtinPut(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 3) return error.TypeError;
    switch (args[0].*) {
        .map => |entries| {
            const key_name = switch (args[1].*) {
                .string => |s| s,
                .atom => |s| s,
                else => return error.TypeError,
            };
            // Check if key exists -- if so, replace; else append
            var found = false;
            var new_entries = allocator.alloc(Value.MapEntry, entries.len + 1) catch return error.OutOfMemory;
            var count: usize = 0;
            for (entries) |entry| {
                if (std.mem.eql(u8, entry.key, key_name)) {
                    new_entries[count] = .{ .key = entry.key, .val = args[2] };
                    found = true;
                } else {
                    new_entries[count] = entry;
                }
                count += 1;
            }
            if (!found) {
                new_entries[count] = .{ .key = key_name, .val = args[2] };
                count += 1;
            }
            const result = allocator.create(Value) catch return error.OutOfMemory;
            result.* = Value{ .map = new_entries[0..count] };
            return result;
        },
        else => return error.TypeError,
    }
}

fn builtinKeys(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1) return error.TypeError;
    switch (args[0].*) {
        .map => |entries| {
            const key_vals = allocator.alloc(*const Value, entries.len) catch return error.OutOfMemory;
            for (entries, 0..) |entry, i| {
                const kv = allocator.create(Value) catch return error.OutOfMemory;
                kv.* = Value{ .string = entry.key };
                key_vals[i] = kv;
            }
            const result = allocator.create(Value) catch return error.OutOfMemory;
            result.* = Value{ .list = key_vals };
            return result;
        },
        else => return error.TypeError,
    }
}

fn builtinNow(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 0) return error.TypeError;
    const builtin = @import("builtin");
    const timestamp: i64 = if (builtin.target.cpu.arch == .wasm32)
        0 // TODO: import JS Date.now() via extern
    else
        std.time.timestamp();
    const result = allocator.create(Value) catch return error.OutOfMemory;
    result.* = Value{ .integer = timestamp };
    return result;
}

// ============================================================
// Tests
// ============================================================

test "builtin length" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const v1 = try alloc.create(Value);
    v1.* = Value{ .integer = 10 };
    const v2 = try alloc.create(Value);
    v2.* = Value{ .integer = 20 };
    const items = try alloc.alloc(*const Value, 2);
    items[0] = v1;
    items[1] = v2;
    const list_val = try alloc.create(Value);
    list_val.* = Value{ .list = items };

    const args = try alloc.alloc(*const Value, 1);
    args[0] = list_val;
    const result = try builtinLength(alloc, args);
    try std.testing.expect(result.eql(Value{ .integer = 2 }));
}

test "builtin max" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const a = try alloc.create(Value);
    a.* = Value{ .integer = 5 };
    const b = try alloc.create(Value);
    b.* = Value{ .integer = 10 };
    const args = try alloc.alloc(*const Value, 2);
    args[0] = a;
    args[1] = b;
    const result = try builtinMax(alloc, args);
    try std.testing.expect(result.eql(Value{ .integer = 10 }));
}

test "builtin min" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const a = try alloc.create(Value);
    a.* = Value{ .integer = 5 };
    const b = try alloc.create(Value);
    b.* = Value{ .integer = 10 };
    const args = try alloc.alloc(*const Value, 2);
    args[0] = a;
    args[1] = b;
    const result = try builtinMin(alloc, args);
    try std.testing.expect(result.eql(Value{ .integer = 5 }));
}

test "builtin append" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const v1 = try alloc.create(Value);
    v1.* = Value{ .integer = 1 };
    const items = try alloc.alloc(*const Value, 1);
    items[0] = v1;
    const list_val = try alloc.create(Value);
    list_val.* = Value{ .list = items };

    const v2 = try alloc.create(Value);
    v2.* = Value{ .integer = 2 };

    const args = try alloc.alloc(*const Value, 2);
    args[0] = list_val;
    args[1] = v2;
    const result = try builtinAppend(alloc, args);
    try std.testing.expect(result.* == .list);
    try std.testing.expectEqual(@as(usize, 2), result.list.len);
}

test "builtin reverse" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const v1 = try alloc.create(Value);
    v1.* = Value{ .integer = 1 };
    const v2 = try alloc.create(Value);
    v2.* = Value{ .integer = 2 };
    const v3 = try alloc.create(Value);
    v3.* = Value{ .integer = 3 };
    const items = try alloc.alloc(*const Value, 3);
    items[0] = v1;
    items[1] = v2;
    items[2] = v3;
    const list_val = try alloc.create(Value);
    list_val.* = Value{ .list = items };

    const args = try alloc.alloc(*const Value, 1);
    args[0] = list_val;
    const result = try builtinReverse(alloc, args);
    try std.testing.expect(result.* == .list);
    try std.testing.expect(result.list[0].eql(Value{ .integer = 3 }));
    try std.testing.expect(result.list[1].eql(Value{ .integer = 2 }));
    try std.testing.expect(result.list[2].eql(Value{ .integer = 1 }));
}

test "builtin lookup found" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const val = try alloc.create(Value);
    val.* = Value{ .integer = 42 };
    const entries = try alloc.alloc(Value.MapEntry, 1);
    entries[0] = .{ .key = "x", .val = val };
    const map_val = try alloc.create(Value);
    map_val.* = Value{ .map = entries };

    const key_val = try alloc.create(Value);
    key_val.* = Value{ .string = "x" };

    const args = try alloc.alloc(*const Value, 2);
    args[0] = map_val;
    args[1] = key_val;
    const result = try builtinLookup(alloc, args);
    try std.testing.expect(result.eql(Value{ .integer = 42 }));
}

test "builtin lookup not found" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const map_val = try alloc.create(Value);
    map_val.* = Value{ .map = &.{} };

    const key_val = try alloc.create(Value);
    key_val.* = Value{ .string = "missing" };

    const args = try alloc.alloc(*const Value, 2);
    args[0] = map_val;
    args[1] = key_val;
    const result = try builtinLookup(alloc, args);
    try std.testing.expect(result.eql(.nil));
}

test "builtin keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const val1 = try alloc.create(Value);
    val1.* = Value{ .integer = 1 };
    const val2 = try alloc.create(Value);
    val2.* = Value{ .integer = 2 };
    const entries = try alloc.alloc(Value.MapEntry, 2);
    entries[0] = .{ .key = "a", .val = val1 };
    entries[1] = .{ .key = "b", .val = val2 };
    const map_val = try alloc.create(Value);
    map_val.* = Value{ .map = entries };

    const args = try alloc.alloc(*const Value, 1);
    args[0] = map_val;
    const result = try builtinKeys(alloc, args);
    try std.testing.expect(result.* == .list);
    try std.testing.expectEqual(@as(usize, 2), result.list.len);
    try std.testing.expect(result.list[0].eql(Value{ .string = "a" }));
    try std.testing.expect(result.list[1].eql(Value{ .string = "b" }));
}

test "builtin put new key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const map_val = try alloc.create(Value);
    map_val.* = Value{ .map = &.{} };

    const key_val = try alloc.create(Value);
    key_val.* = Value{ .string = "x" };
    const new_val = try alloc.create(Value);
    new_val.* = Value{ .integer = 99 };

    const args = try alloc.alloc(*const Value, 3);
    args[0] = map_val;
    args[1] = key_val;
    args[2] = new_val;
    const result = try builtinPut(alloc, args);
    try std.testing.expect(result.* == .map);
    try std.testing.expectEqual(@as(usize, 1), result.map.len);
    try std.testing.expect(std.mem.eql(u8, result.map[0].key, "x"));
    try std.testing.expect(result.map[0].val.eql(Value{ .integer = 99 }));
}

test "builtin now returns integer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const args = try alloc.alloc(*const Value, 0);
    const result = try builtinNow(alloc, args);
    try std.testing.expect(result.* == .integer);
}
