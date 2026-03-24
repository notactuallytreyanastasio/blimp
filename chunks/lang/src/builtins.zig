const std = @import("std");
const Value = @import("value.zig").Value;

pub const EvalError = error{
    UndefinedVariable,
    TypeError,
    UnsupportedOperation,
    DivisionByZero,
    NotSupported,
    OutOfMemory,
    Bubble, // Actor failure propagation
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
        reg.register("concat", &builtinConcat);
        reg.register("split", &builtinSplit);
        reg.register("contains", &builtinContains);
        reg.register("to_string", &builtinToString);
        reg.register("to_int", &builtinToInt);
        reg.register("slice", &builtinSlice);
        reg.register("upcase", &builtinUpcase);
        reg.register("downcase", &builtinDowncase);
        reg.register("range", &builtinRange);
        reg.register("head", &builtinHead);
        reg.register("tail", &builtinTail);
        reg.register("sort", &builtinSort);
        reg.register("merge", &builtinMerge);
        reg.register("values", &builtinValues);
        reg.register("type_of", &builtinTypeOf);
        reg.register("print", &builtinPrint);
        reg.register("rem", &builtinRem);
        reg.register("abs", &builtinAbs);
        reg.register("nil?", &builtinIsNil);
        reg.register("elem", &builtinElem);
        reg.register("floor", &builtinFloor);
        reg.register("ceil", &builtinCeil);
        reg.register("round", &builtinRound);
        reg.register("not", &builtinNot);
        reg.register("size", &builtinSize);
        reg.register("empty?", &builtinIsEmpty);
        reg.register("flat", &builtinFlat);
        reg.register("zip", &builtinZip);
        reg.register("uniq", &builtinUniq);
        reg.register("sum", &builtinSum);
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
        .string => |s| {
            const result = allocator.create(Value) catch return error.OutOfMemory;
            result.* = Value{ .integer = @intCast(s.len) };
            return result;
        },
        .map => |entries| {
            const result = allocator.create(Value) catch return error.OutOfMemory;
            result.* = Value{ .integer = @intCast(entries.len) };
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

// ── String builtins ─────────────────────────────────────

/// concat("hello", " ", "world") => "hello world"
fn builtinConcat(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len < 2) return error.TypeError;
    var total_len: usize = 0;
    for (args) |arg| {
        switch (arg.*) {
            .string => |s| total_len += s.len,
            .integer => |n| {
                total_len += @intCast(std.fmt.count("{d}", .{n}));
            },
            .atom => |a| total_len += a.len + 1,
            else => return error.TypeError,
        }
    }
    var buf = allocator.alloc(u8, total_len) catch return error.OutOfMemory;
    var pos: usize = 0;
    for (args) |arg| {
        switch (arg.*) {
            .string => |s| {
                @memcpy(buf[pos .. pos + s.len], s);
                pos += s.len;
            },
            .integer => |n| {
                const written = std.fmt.bufPrint(buf[pos..], "{d}", .{n}) catch "";
                pos += written.len;
            },
            .atom => |a| {
                buf[pos] = ':';
                pos += 1;
                @memcpy(buf[pos .. pos + a.len], a);
                pos += a.len;
            },
            else => {},
        }
    }
    const result = allocator.create(Value) catch return error.OutOfMemory;
    result.* = Value{ .string = buf[0..pos] };
    return result;
}

/// split("a,b,c", ",") => ["a", "b", "c"]
fn builtinSplit(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 2) return error.TypeError;
    if (args[0].* != .string or args[1].* != .string) return error.TypeError;
    const str = args[0].string;
    const sep = args[1].string;

    var parts: std.ArrayList(*const Value) = .{ .items = &.{}, .capacity = 0 };
    var start: usize = 0;
    var i: usize = 0;
    while (i + sep.len <= str.len) : (i += 1) {
        if (std.mem.eql(u8, str[i .. i + sep.len], sep)) {
            const part = allocator.create(Value) catch return error.OutOfMemory;
            part.* = Value{ .string = str[start..i] };
            parts.append(allocator, part) catch return error.OutOfMemory;
            i += sep.len;
            start = i;
            continue;
        }
    }
    // Last segment
    const last = allocator.create(Value) catch return error.OutOfMemory;
    last.* = Value{ .string = str[start..] };
    parts.append(allocator, last) catch return error.OutOfMemory;

    const result = allocator.create(Value) catch return error.OutOfMemory;
    result.* = Value{ .list = parts.toOwnedSlice(allocator) catch return error.OutOfMemory };
    return result;
}

/// contains("hello world", "world") => true
fn builtinContains(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 2) return error.TypeError;
    if (args[0].* != .string or args[1].* != .string) return error.TypeError;
    const found = std.mem.indexOf(u8, args[0].string, args[1].string) != null;
    const result = allocator.create(Value) catch return error.OutOfMemory;
    result.* = Value{ .boolean = found };
    return result;
}

/// to_string(42) => "42", to_string(:ok) => "ok"
fn builtinToString(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1) return error.TypeError;
    const result = allocator.create(Value) catch return error.OutOfMemory;
    switch (args[0].*) {
        .string => return args[0],
        .integer => |n| {
            result.* = Value{ .string = std.fmt.allocPrint(allocator, "{d}", .{n}) catch return error.OutOfMemory };
        },
        .float => |f| {
            result.* = Value{ .string = std.fmt.allocPrint(allocator, "{d}", .{f}) catch return error.OutOfMemory };
        },
        .atom => |a| {
            result.* = Value{ .string = a };
        },
        .boolean => |b| {
            result.* = Value{ .string = if (b) "true" else "false" };
        },
        .nil => {
            result.* = Value{ .string = "nil" };
        },
        else => return error.TypeError,
    }
    return result;
}

/// to_int("42") => 42
fn builtinToInt(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1) return error.TypeError;
    const result = allocator.create(Value) catch return error.OutOfMemory;
    switch (args[0].*) {
        .integer => return args[0],
        .string => |s| {
            const n = std.fmt.parseInt(i64, s, 10) catch return error.TypeError;
            result.* = Value{ .integer = n };
        },
        .float => |f| {
            result.* = Value{ .integer = @intFromFloat(f) };
        },
        .boolean => |b| {
            result.* = Value{ .integer = if (b) 1 else 0 };
        },
        else => return error.TypeError,
    }
    return result;
}

/// slice("hello", 1, 3) => "ell"
fn builtinSlice(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 3) return error.TypeError;
    if (args[0].* != .string or args[1].* != .integer or args[2].* != .integer) return error.TypeError;
    const str = args[0].string;
    const start: usize = @intCast(@max(args[1].integer, 0));
    const end: usize = @intCast(@min(args[2].integer, @as(i64, @intCast(str.len))));
    if (start >= str.len or start >= end) {
        const result = allocator.create(Value) catch return error.OutOfMemory;
        result.* = Value{ .string = "" };
        return result;
    }
    const result = allocator.create(Value) catch return error.OutOfMemory;
    result.* = Value{ .string = str[start..end] };
    return result;
}

/// upcase("hello") => "HELLO"
fn builtinUpcase(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1 or args[0].* != .string) return error.TypeError;
    const src = args[0].string;
    var buf = allocator.alloc(u8, src.len) catch return error.OutOfMemory;
    for (src, 0..) |c, i| {
        buf[i] = if (c >= 'a' and c <= 'z') c - 32 else c;
    }
    const result = allocator.create(Value) catch return error.OutOfMemory;
    result.* = Value{ .string = buf };
    return result;
}

/// downcase("HELLO") => "hello"
fn builtinDowncase(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1 or args[0].* != .string) return error.TypeError;
    const src = args[0].string;
    var buf = allocator.alloc(u8, src.len) catch return error.OutOfMemory;
    for (src, 0..) |c, i| {
        buf[i] = if (c >= 'A' and c <= 'Z') c + 32 else c;
    }
    const result = allocator.create(Value) catch return error.OutOfMemory;
    result.* = Value{ .string = buf };
    return result;
}

// ── Collection builtins ─────────────────────────────────

/// range(1, 5) => [1, 2, 3, 4, 5]
fn builtinRange(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 2) return error.TypeError;
    if (args[0].* != .integer or args[1].* != .integer) return error.TypeError;
    const start = args[0].integer;
    const end_val = args[1].integer;
    const len: usize = if (end_val >= start) @intCast(end_val - start + 1) else 0;

    var items = allocator.alloc(*const Value, len) catch return error.OutOfMemory;
    var i: usize = 0;
    var n = start;
    while (n <= end_val) : (n += 1) {
        const v = allocator.create(Value) catch return error.OutOfMemory;
        v.* = Value{ .integer = n };
        items[i] = v;
        i += 1;
    }

    const result = allocator.create(Value) catch return error.OutOfMemory;
    result.* = Value{ .list = items };
    return result;
}

/// head([1, 2, 3]) => 1
fn builtinHead(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1 or args[0].* != .list) return error.TypeError;
    if (args[0].list.len == 0) {
        const result = allocator.create(Value) catch return error.OutOfMemory;
        result.* = .nil;
        return result;
    }
    return args[0].list[0];
}

/// tail([1, 2, 3]) => [2, 3]
fn builtinTail(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1 or args[0].* != .list) return error.TypeError;
    const result = allocator.create(Value) catch return error.OutOfMemory;
    if (args[0].list.len <= 1) {
        result.* = Value{ .list = &.{} };
    } else {
        result.* = Value{ .list = args[0].list[1..] };
    }
    return result;
}

/// sort([3, 1, 2]) => [1, 2, 3]
fn builtinSort(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1 or args[0].* != .list) return error.TypeError;
    const src = args[0].list;
    var items = allocator.alloc(*const Value, src.len) catch return error.OutOfMemory;
    @memcpy(items, src);

    // Simple insertion sort on integers
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        var j = i;
        while (j > 0) {
            const a_val = if (items[j - 1].* == .integer) items[j - 1].integer else @as(i64, 0);
            const b_val = if (items[j].* == .integer) items[j].integer else @as(i64, 0);
            if (a_val > b_val) {
                const tmp = items[j - 1];
                items[j - 1] = items[j];
                items[j] = tmp;
            }
            j -= 1;
        }
    }

    const result = allocator.create(Value) catch return error.OutOfMemory;
    result.* = Value{ .list = items };
    return result;
}

// ── Map and utility builtins ────────────────────────────

/// merge(%{a: 1}, %{b: 2}) => %{a: 1, b: 2}
fn builtinMerge(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 2) return error.TypeError;
    if (args[0].* != .map or args[1].* != .map) return error.TypeError;
    const a = args[0].map;
    const b = args[1].map;

    // Start with all entries from a, then add/overwrite from b
    var entries: std.ArrayList(Value.MapEntry) = .{ .items = &.{}, .capacity = 0 };
    for (a) |entry| {
        entries.append(allocator, entry) catch return error.OutOfMemory;
    }
    for (b) |new_entry| {
        var found = false;
        for (entries.items) |*existing| {
            if (std.mem.eql(u8, existing.key, new_entry.key)) {
                existing.val = new_entry.val;
                found = true;
                break;
            }
        }
        if (!found) {
            entries.append(allocator, new_entry) catch return error.OutOfMemory;
        }
    }

    const result = allocator.create(Value) catch return error.OutOfMemory;
    result.* = Value{ .map = entries.toOwnedSlice(allocator) catch return error.OutOfMemory };
    return result;
}

/// values(%{a: 1, b: 2}) => [1, 2]
fn builtinValues(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1 or args[0].* != .map) return error.TypeError;
    const entries = args[0].map;
    var items = allocator.alloc(*const Value, entries.len) catch return error.OutOfMemory;
    for (entries, 0..) |entry, i| {
        items[i] = entry.val;
    }
    const result = allocator.create(Value) catch return error.OutOfMemory;
    result.* = Value{ .list = items };
    return result;
}

/// type_of(42) => :integer, type_of("hi") => :string, etc.
fn builtinTypeOf(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1) return error.TypeError;
    const result = allocator.create(Value) catch return error.OutOfMemory;
    const type_name: []const u8 = switch (args[0].*) {
        .integer => "integer",
        .float => "float",
        .string => "string",
        .atom => "atom",
        .boolean => "boolean",
        .nil => "nil",
        .hole => "hole",
        .list => "list",
        .tuple => "tuple",
        .map => "map",
        .actor_ref => "actor_ref",
        .closure => "closure",
    };
    result.* = Value{ .atom = type_name };
    return result;
}

/// print(value) => prints to stdout, returns the value (identity)
fn builtinPrint(_: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1) return error.TypeError;
    // Write to a buffer and print
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    args[0].format(fbs.writer());
    const builtin = @import("builtin");
    if (builtin.target.cpu.arch != .wasm32) {
        const stdout = std.fs.File.stdout();
        stdout.writeAll(fbs.getWritten()) catch {};
        stdout.writeAll("\n") catch {};
    }
    return args[0]; // return the value (identity)
}

// ── Math and utility builtins ───────────────────────────

/// rem(10, 3) => 1 (integer remainder)
fn builtinRem(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 2) return error.TypeError;
    if (args[0].* != .integer or args[1].* != .integer) return error.TypeError;
    if (args[1].integer == 0) return error.DivisionByZero;
    const result = allocator.create(Value) catch return error.OutOfMemory;
    result.* = Value{ .integer = @rem(args[0].integer, args[1].integer) };
    return result;
}

/// abs(-5) => 5
fn builtinAbs(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1) return error.TypeError;
    const result = allocator.create(Value) catch return error.OutOfMemory;
    switch (args[0].*) {
        .integer => |n| result.* = Value{ .integer = if (n < 0) -n else n },
        .float => |f| result.* = Value{ .float = if (f < 0) -f else f },
        else => return error.TypeError,
    }
    return result;
}

/// nil?(nil) => true, nil?(42) => false
fn builtinIsNil(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1) return error.TypeError;
    const result = allocator.create(Value) catch return error.OutOfMemory;
    result.* = Value{ .boolean = args[0].* == .nil };
    return result;
}

/// elem({10, 20, 30}, 1) => 20 (0-indexed tuple access)
fn builtinElem(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 2) return error.TypeError;
    if (args[1].* != .integer) return error.TypeError;
    const idx: usize = @intCast(@max(args[1].integer, 0));
    switch (args[0].*) {
        .tuple => |items| {
            if (idx >= items.len) {
                const result = allocator.create(Value) catch return error.OutOfMemory;
                result.* = .nil;
                return result;
            }
            return items[idx];
        },
        .list => |items| {
            if (idx >= items.len) {
                const result = allocator.create(Value) catch return error.OutOfMemory;
                result.* = .nil;
                return result;
            }
            return items[idx];
        },
        else => return error.TypeError,
    }
}

/// floor(3.7) => 3
fn builtinFloor(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1) return error.TypeError;
    const result = allocator.create(Value) catch return error.OutOfMemory;
    switch (args[0].*) {
        .float => |f| result.* = Value{ .integer = @intFromFloat(@floor(f)) },
        .integer => return args[0],
        else => return error.TypeError,
    }
    return result;
}

/// ceil(3.2) => 4
fn builtinCeil(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1) return error.TypeError;
    const result = allocator.create(Value) catch return error.OutOfMemory;
    switch (args[0].*) {
        .float => |f| result.* = Value{ .integer = @intFromFloat(@ceil(f)) },
        .integer => return args[0],
        else => return error.TypeError,
    }
    return result;
}

/// round(3.5) => 4
fn builtinRound(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1) return error.TypeError;
    const result = allocator.create(Value) catch return error.OutOfMemory;
    switch (args[0].*) {
        .float => |f| result.* = Value{ .integer = @intFromFloat(@round(f)) },
        .integer => return args[0],
        else => return error.TypeError,
    }
    return result;
}

// ── Logic and collection builtins ───────────────────────

/// not(true) => false
fn builtinNot(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1) return error.TypeError;
    const result = allocator.create(Value) catch return error.OutOfMemory;
    result.* = Value{ .boolean = !args[0].truthy() };
    return result;
}

/// size(collection) => length (alias for length)
fn builtinSize(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    return builtinLength(allocator, args);
}

/// empty?([]) => true, empty?([1]) => false
fn builtinIsEmpty(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1) return error.TypeError;
    const result = allocator.create(Value) catch return error.OutOfMemory;
    result.* = Value{ .boolean = switch (args[0].*) {
        .list => |items| items.len == 0,
        .map => |entries| entries.len == 0,
        .string => |s| s.len == 0,
        .nil => true,
        else => false,
    } };
    return result;
}

/// flat([[1,2],[3,4]]) => [1,2,3,4]
fn builtinFlat(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1 or args[0].* != .list) return error.TypeError;
    var items: std.ArrayList(*const Value) = .{ .items = &.{}, .capacity = 0 };
    for (args[0].list) |item| {
        if (item.* == .list) {
            for (item.list) |inner| {
                items.append(allocator, inner) catch return error.OutOfMemory;
            }
        } else {
            items.append(allocator, item) catch return error.OutOfMemory;
        }
    }
    const result = allocator.create(Value) catch return error.OutOfMemory;
    result.* = Value{ .list = items.toOwnedSlice(allocator) catch return error.OutOfMemory };
    return result;
}

/// zip([1,2,3], [:a,:b,:c]) => [{1,:a},{2,:b},{3,:c}]
fn builtinZip(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 2 or args[0].* != .list or args[1].* != .list) return error.TypeError;
    const a = args[0].list;
    const b = args[1].list;
    const len = @min(a.len, b.len);
    var items = allocator.alloc(*const Value, len) catch return error.OutOfMemory;
    for (0..len) |i| {
        const pair = allocator.alloc(*const Value, 2) catch return error.OutOfMemory;
        pair[0] = a[i];
        pair[1] = b[i];
        const tuple_val = allocator.create(Value) catch return error.OutOfMemory;
        tuple_val.* = Value{ .tuple = pair };
        items[i] = tuple_val;
    }
    const result = allocator.create(Value) catch return error.OutOfMemory;
    result.* = Value{ .list = items };
    return result;
}

/// uniq([1,2,1,3,2]) => [1,2,3]
fn builtinUniq(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1 or args[0].* != .list) return error.TypeError;
    var items: std.ArrayList(*const Value) = .{ .items = &.{}, .capacity = 0 };
    for (args[0].list) |item| {
        var found = false;
        for (items.items) |existing| {
            if (existing.eql(item.*)) { found = true; break; }
        }
        if (!found) items.append(allocator, item) catch return error.OutOfMemory;
    }
    const result = allocator.create(Value) catch return error.OutOfMemory;
    result.* = Value{ .list = items.toOwnedSlice(allocator) catch return error.OutOfMemory };
    return result;
}

/// sum([1,2,3]) => 6
fn builtinSum(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1 or args[0].* != .list) return error.TypeError;
    var total: i64 = 0;
    for (args[0].list) |item| {
        if (item.* == .integer) total += item.integer;
    }
    const result = allocator.create(Value) catch return error.OutOfMemory;
    result.* = Value{ .integer = total };
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
