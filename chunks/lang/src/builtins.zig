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
        reg.register("to_atom", &builtinToAtom);
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
        reg.register("actor_name", &builtinActorName);
        reg.register("print", &builtinPrint);
        reg.register("rem", &builtinRem);
        reg.register("abs", &builtinAbs);
        reg.register("nil?", &builtinIsNil);
        reg.register("elem", &builtinElem);
        reg.register("floor", &builtinFloor);
        reg.register("ceil", &builtinCeil);
        reg.register("round", &builtinRound);
        reg.register("not", &builtinNot);
        reg.register("random", &builtinRandom);
        reg.register("size", &builtinSize);
        reg.register("empty?", &builtinIsEmpty);
        reg.register("flat", &builtinFlat);
        reg.register("zip", &builtinZip);
        reg.register("uniq", &builtinUniq);
        reg.register("sum", &builtinSum);
        reg.register("set_at", &builtinSetAt);
        // View primitives
        reg.register("stack", &viewStack);
        reg.register("row", &viewRow);
        reg.register("grid", &viewGrid);
        reg.register("text", &viewText);
        reg.register("heading", &viewHeading);
        reg.register("bold", &viewBold);
        reg.register("italic", &viewItalic);
        reg.register("code", &viewCode);
        reg.register("code_block", &viewCodeBlock);
        reg.register("blockquote", &viewBlockquote);
        reg.register("divider", &viewDivider);
        reg.register("list", &viewList);
        reg.register("link", &viewLink);
        reg.register("image", &viewImage);
        reg.register("video", &viewVideo);
        reg.register("canvas", &viewCanvas);
        reg.register("button", &viewButton);
        reg.register("mount_root", &viewMountRoot);
        // HTTP / TCP builtins (native only)
        reg.register("to_html", &builtinToHtml);
        reg.register("tcp_listen", &builtinTcpListen);
        reg.register("tcp_accept", &builtinTcpAccept);
        reg.register("tcp_read", &builtinTcpRead);
        reg.register("tcp_write", &builtinTcpWrite);
        reg.register("tcp_close", &builtinTcpClose);
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

/// to_atom("hello") => :hello — converts a string to an atom
fn builtinToAtom(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1) return error.TypeError;
    switch (args[0].*) {
        .string => |s| {
            const result = allocator.create(Value) catch return error.OutOfMemory;
            result.* = Value{ .atom = s };
            return result;
        },
        .atom => return args[0],
        else => return error.TypeError,
    }
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
        .view_node => "view_node",
    };
    result.* = Value{ .atom = type_name };
    return result;
}

/// actor_name(actor_ref) -> String: returns the type name of an actor reference
/// e.g. actor_name(Counter) => "Counter", actor_name(Shop.Checkout) => "Shop.Checkout"
fn builtinActorName(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1) return error.TypeError;
    switch (args[0].*) {
        .actor_ref => |ref| {
            const result = allocator.create(Value) catch return error.OutOfMemory;
            result.* = Value{ .string = ref.type_name };
            return result;
        },
        else => return error.TypeError,
    }
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

/// set_at(list, index, value) => new list with element at index replaced
fn builtinSetAt(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 3 or args[0].* != .list or args[1].* != .integer) return error.TypeError;
    const items = args[0].list;
    const idx: usize = @intCast(@max(args[1].integer, 0));
    if (idx >= items.len) return error.TypeError;
    const new_items = allocator.dupe(*const Value, items) catch return error.OutOfMemory;
    new_items[idx] = args[2];
    const result = allocator.create(Value) catch return error.OutOfMemory;
    result.* = Value{ .list = new_items };
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

/// random(min, max) => random integer in [min, max] inclusive
var random_state: u64 = 0x853c49e6748fea9b;

fn builtinRandom(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 2) return error.TypeError;
    if (args[0].* != .integer or args[1].* != .integer) return error.TypeError;
    const min_val = args[0].integer;
    const max_val = args[1].integer;
    if (max_val < min_val) return error.TypeError;

    // xorshift64
    random_state ^= random_state << 13;
    random_state ^= random_state >> 7;
    random_state ^= random_state << 17;

    const range: u64 = @intCast(max_val - min_val + 1);
    const val = min_val + @as(i64, @intCast(random_state % range));

    const result = allocator.create(Value) catch return error.OutOfMemory;
    result.* = Value{ .integer = val };
    return result;
}

// ============================================================
// View primitive helpers
// ============================================================

const ViewAttr = Value.ViewNode.ViewAttr;

/// Build a view_node with the given tag, no attrs, and variadic children (all must be view_node or string).
fn makeViewNode(allocator: std.mem.Allocator, tag: []const u8, attrs: []const ViewAttr, children: []const *const Value) EvalError!*const Value {
    const node_attrs = allocator.dupe(ViewAttr, attrs) catch return error.OutOfMemory;
    const node_children = allocator.dupe(*const Value, children) catch return error.OutOfMemory;
    const result = allocator.create(Value) catch return error.OutOfMemory;
    result.* = Value{ .view_node = .{ .tag = tag, .attrs = node_attrs, .children = node_children } };
    return result;
}

/// stack(child, child, ...) — vertical flex container, variadic children
fn viewStack(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    return makeViewNode(allocator, "stack", &.{}, args);
}

/// row(child, child, ...) — horizontal flex container, variadic children
fn viewRow(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    return makeViewNode(allocator, "row", &.{}, args);
}

/// grid(child, child, ...) — grid container, variadic children
fn viewGrid(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    return makeViewNode(allocator, "grid", &.{}, args);
}

/// text("content") — inline text node
fn viewText(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1) return error.TypeError;
    if (args[0].* != .string) return error.TypeError;
    return makeViewNode(allocator, "text", &.{}, args[0..1]);
}

/// heading("content", level) — h1-h6. Level defaults to 1 if omitted.
fn viewHeading(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len < 1 or args.len > 2) return error.TypeError;
    if (args[0].* != .string) return error.TypeError;
    const level: i64 = if (args.len == 2 and args[1].* == .integer) args[1].integer else 1;
    const level_val = allocator.create(Value) catch return error.OutOfMemory;
    level_val.* = Value{ .integer = level };
    const attrs = try allocator.alloc(ViewAttr, 1);
    attrs[0] = .{ .key = "level", .val = level_val };
    return makeViewNode(allocator, "heading", attrs, args[0..1]);
}

/// bold("content") — bold/strong text
fn viewBold(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1 or args[0].* != .string) return error.TypeError;
    return makeViewNode(allocator, "bold", &.{}, args[0..1]);
}

/// italic("content") — italic/em text
fn viewItalic(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1 or args[0].* != .string) return error.TypeError;
    return makeViewNode(allocator, "italic", &.{}, args[0..1]);
}

/// code("content") — inline code span
fn viewCode(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1 or args[0].* != .string) return error.TypeError;
    return makeViewNode(allocator, "code", &.{}, args[0..1]);
}

/// code_block("content") — fenced code block, optional lang atom
fn viewCodeBlock(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len < 1 or args.len > 2) return error.TypeError;
    if (args[0].* != .string) return error.TypeError;
    if (args.len == 2) {
        if (args[1].* != .atom) return error.TypeError;
        const attrs = try allocator.alloc(ViewAttr, 1);
        attrs[0] = .{ .key = "lang", .val = args[1] };
        return makeViewNode(allocator, "code_block", attrs, args[0..1]);
    }
    return makeViewNode(allocator, "code_block", &.{}, args[0..1]);
}

/// blockquote("content") — block quote
fn viewBlockquote(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1 or args[0].* != .string) return error.TypeError;
    return makeViewNode(allocator, "blockquote", &.{}, args[0..1]);
}

/// divider() — horizontal rule
fn viewDivider(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 0) return error.TypeError;
    return makeViewNode(allocator, "divider", &.{}, &.{});
}

/// list(item, item, ...) — unordered list with variadic items
fn viewList(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    return makeViewNode(allocator, "list", &.{}, args);
}

/// link("label", "url") — anchor link
fn viewLink(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 2) return error.TypeError;
    if (args[0].* != .string or args[1].* != .string) return error.TypeError;
    const attrs = try allocator.alloc(ViewAttr, 1);
    attrs[0] = .{ .key = "href", .val = args[1] };
    return makeViewNode(allocator, "link", attrs, args[0..1]);
}

/// image("src", "alt") — img embed, alt optional
fn viewImage(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len < 1 or args.len > 2) return error.TypeError;
    if (args[0].* != .string) return error.TypeError;
    if (args.len == 2) {
        if (args[1].* != .string) return error.TypeError;
        const attrs = try allocator.alloc(ViewAttr, 2);
        attrs[0] = .{ .key = "src", .val = args[0] };
        attrs[1] = .{ .key = "alt", .val = args[1] };
        return makeViewNode(allocator, "image", attrs, &.{});
    }
    const attrs = try allocator.alloc(ViewAttr, 1);
    attrs[0] = .{ .key = "src", .val = args[0] };
    return makeViewNode(allocator, "image", attrs, &.{});
}

/// video("src") — video embed
fn viewVideo(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1 or args[0].* != .string) return error.TypeError;
    const attrs = try allocator.alloc(ViewAttr, 1);
    attrs[0] = .{ .key = "src", .val = args[0] };
    return makeViewNode(allocator, "video", attrs, &.{});
}

/// canvas("id") — canvas element for 2D drawing
fn viewCanvas(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1 or args[0].* != .string) return error.TypeError;
    const attrs = try allocator.alloc(ViewAttr, 1);
    attrs[0] = .{ .key = "id", .val = args[0] };
    return makeViewNode(allocator, "canvas", attrs, &.{});
}

/// button("label", sends_atom) — clickable button that sends a message to the actor
fn viewButton(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len < 1 or args.len > 2) return error.TypeError;
    if (args[0].* != .string) return error.TypeError;
    if (args.len == 2) {
        if (args[1].* != .atom) return error.TypeError;
        const attrs = try allocator.alloc(ViewAttr, 1);
        attrs[0] = .{ .key = "sends", .val = args[1] };
        return makeViewNode(allocator, "button", attrs, args[0..1]);
    }
    return makeViewNode(allocator, "button", &.{}, args[0..1]);
}

/// mount_root("ActorName", view_node) — wraps a child actor's view in a mount boundary
/// Creates a ViewNode with tag "mount" and data-actor attr for message routing.
/// Used by the Blimp-level mount() helper: mount(Actor) calls Actor <- :render
/// and wraps the result with mount_root(name, view).
fn viewMountRoot(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 2) return error.TypeError;
    if (args[0].* != .string) return error.TypeError;
    if (args[1].* != .view_node) return error.TypeError;
    const attrs = try allocator.alloc(ViewAttr, 1);
    attrs[0] = .{ .key = "data-actor", .val = args[0] };
    return makeViewNode(allocator, "mount", attrs, args[1..2]);
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

test "view text produces view_node with tag text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const str = try alloc.create(Value);
    str.* = Value{ .string = "hello" };
    const args = try alloc.alloc(*const Value, 1);
    args[0] = str;
    const result = try viewText(alloc, args);
    try std.testing.expect(result.* == .view_node);
    try std.testing.expectEqualStrings("text", result.view_node.tag);
    try std.testing.expectEqual(@as(usize, 1), result.view_node.children.len);
    try std.testing.expect(result.view_node.children[0].eql(Value{ .string = "hello" }));
}

test "view heading defaults to level 1" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const str = try alloc.create(Value);
    str.* = Value{ .string = "Title" };
    const args = try alloc.alloc(*const Value, 1);
    args[0] = str;
    const result = try viewHeading(alloc, args);
    try std.testing.expect(result.* == .view_node);
    try std.testing.expectEqualStrings("heading", result.view_node.tag);
    try std.testing.expectEqual(@as(usize, 1), result.view_node.attrs.len);
    try std.testing.expect(result.view_node.attrs[0].val.eql(Value{ .integer = 1 }));
}

test "view heading with explicit level" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const str = try alloc.create(Value);
    str.* = Value{ .string = "Sub" };
    const lvl = try alloc.create(Value);
    lvl.* = Value{ .integer = 3 };
    const args = try alloc.alloc(*const Value, 2);
    args[0] = str;
    args[1] = lvl;
    const result = try viewHeading(alloc, args);
    try std.testing.expect(result.view_node.attrs[0].val.eql(Value{ .integer = 3 }));
}

test "view stack variadic children" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const c1 = try alloc.create(Value);
    const c1_str = try alloc.create(Value);
    c1_str.* = Value{ .string = "a" };
    c1.* = Value{ .view_node = .{ .tag = "text", .attrs = &.{}, .children = &.{c1_str} } };
    const c2 = try alloc.create(Value);
    const c2_str = try alloc.create(Value);
    c2_str.* = Value{ .string = "b" };
    c2.* = Value{ .view_node = .{ .tag = "text", .attrs = &.{}, .children = &.{c2_str} } };

    const args = try alloc.alloc(*const Value, 2);
    args[0] = c1;
    args[1] = c2;
    const result = try viewStack(alloc, args);
    try std.testing.expectEqualStrings("stack", result.view_node.tag);
    try std.testing.expectEqual(@as(usize, 2), result.view_node.children.len);
}

test "view button with sends atom" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const label = try alloc.create(Value);
    label.* = Value{ .string = "Click me" };
    const msg = try alloc.create(Value);
    msg.* = Value{ .atom = "checkout" };
    const args = try alloc.alloc(*const Value, 2);
    args[0] = label;
    args[1] = msg;
    const result = try viewButton(alloc, args);
    try std.testing.expectEqualStrings("button", result.view_node.tag);
    try std.testing.expectEqualStrings("sends", result.view_node.attrs[0].key);
    try std.testing.expect(result.view_node.attrs[0].val.eql(Value{ .atom = "checkout" }));
}

test "view image with src and alt" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const src = try alloc.create(Value);
    src.* = Value{ .string = "/img/logo.png" };
    const alt = try alloc.create(Value);
    alt.* = Value{ .string = "Logo" };
    const args = try alloc.alloc(*const Value, 2);
    args[0] = src;
    args[1] = alt;
    const result = try viewImage(alloc, args);
    try std.testing.expectEqualStrings("image", result.view_node.tag);
    try std.testing.expectEqual(@as(usize, 2), result.view_node.attrs.len);
    try std.testing.expectEqualStrings("src", result.view_node.attrs[0].key);
    try std.testing.expectEqualStrings("alt", result.view_node.attrs[1].key);
}

test "view canvas with id" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const id = try alloc.create(Value);
    id.* = Value{ .string = "main-canvas" };
    const args = try alloc.alloc(*const Value, 1);
    args[0] = id;
    const result = try viewCanvas(alloc, args);
    try std.testing.expectEqualStrings("canvas", result.view_node.tag);
    try std.testing.expectEqualStrings("id", result.view_node.attrs[0].key);
}

test "view divider takes no args" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const args = try alloc.alloc(*const Value, 0);
    const result = try viewDivider(alloc, args);
    try std.testing.expectEqualStrings("divider", result.view_node.tag);
    try std.testing.expectEqual(@as(usize, 0), result.view_node.children.len);
}

test "view link with href" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const label = try alloc.create(Value);
    label.* = Value{ .string = "Click here" };
    const href = try alloc.create(Value);
    href.* = Value{ .string = "https://example.com" };
    const args = try alloc.alloc(*const Value, 2);
    args[0] = label;
    args[1] = href;
    const result = try viewLink(alloc, args);
    try std.testing.expectEqualStrings("link", result.view_node.tag);
    try std.testing.expectEqualStrings("href", result.view_node.attrs[0].key);
}

test "view code_block with lang" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const content = try alloc.create(Value);
    content.* = Value{ .string = "x = 42" };
    const lang = try alloc.create(Value);
    lang.* = Value{ .atom = "blimp" };
    const args = try alloc.alloc(*const Value, 2);
    args[0] = content;
    args[1] = lang;
    const result = try viewCodeBlock(alloc, args);
    try std.testing.expectEqualStrings("code_block", result.view_node.tag);
    try std.testing.expectEqualStrings("lang", result.view_node.attrs[0].key);
    try std.testing.expect(result.view_node.attrs[0].val.eql(Value{ .atom = "blimp" }));
}

// ============================================================
// HTTP / TCP builtins
// ============================================================

/// to_html(view_node) -> String
/// Renders a view_node tree to an HTML string.
fn builtinToHtml(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1) return error.TypeError;
    var buf: std.ArrayListUnmanaged(u8) = .{};
    renderHtml(allocator, args[0], &buf) catch return error.OutOfMemory;
    const result = allocator.create(Value) catch return error.OutOfMemory;
    result.* = Value{ .string = buf.toOwnedSlice(allocator) catch return error.OutOfMemory };
    return result;
}

fn renderHtml(allocator: std.mem.Allocator, val: *const Value, buf: *std.ArrayListUnmanaged(u8)) !void {
    switch (val.*) {
        .view_node => |node| {
            const tag = blimpTagToHtml(node.tag);
            try buf.appendSlice(allocator, "<");
            try buf.appendSlice(allocator, tag);
            if (std.mem.eql(u8, node.tag, "row")) {
                try buf.appendSlice(allocator, " data-row");
            }
            for (node.attrs) |attr| {
                if (std.mem.eql(u8, attr.key, "href")) {
                    var val_buf: [512]u8 = undefined;
                    var fbs = std.io.fixedBufferStream(&val_buf);
                    attr.val.format(fbs.writer());
                    const raw = fbs.getWritten();
                    const href = if (raw.len >= 2 and raw[0] == '"') raw[1 .. raw.len - 1] else raw;
                    try buf.appendSlice(allocator, " href=\"");
                    try buf.appendSlice(allocator, href);
                    try buf.appendSlice(allocator, "\"");
                } else if (std.mem.eql(u8, attr.key, "src")) {
                    var val_buf: [512]u8 = undefined;
                    var fbs = std.io.fixedBufferStream(&val_buf);
                    attr.val.format(fbs.writer());
                    const raw = fbs.getWritten();
                    const src = if (raw.len >= 2 and raw[0] == '"') raw[1 .. raw.len - 1] else raw;
                    try buf.appendSlice(allocator, " src=\"");
                    try buf.appendSlice(allocator, src);
                    try buf.appendSlice(allocator, "\"");
                } else if (std.mem.eql(u8, attr.key, "sends")) {
                    var val_buf: [256]u8 = undefined;
                    var fbs = std.io.fixedBufferStream(&val_buf);
                    attr.val.format(fbs.writer());
                    const raw = fbs.getWritten();
                    const msg = if (raw.len > 0 and raw[0] == ':') raw[1..] else raw;
                    try buf.appendSlice(allocator, " data-sends=\"");
                    try buf.appendSlice(allocator, msg);
                    try buf.appendSlice(allocator, "\" onclick=\"blimpSend(this)\"");
                } else if (std.mem.eql(u8, attr.key, "level")) {
                    // heading level - handled in tag mapping
                } else if (std.mem.eql(u8, attr.key, "lang")) {
                    var val_buf: [64]u8 = undefined;
                    var fbs = std.io.fixedBufferStream(&val_buf);
                    attr.val.format(fbs.writer());
                    const raw = fbs.getWritten();
                    const lang = if (raw.len > 0 and raw[0] == ':') raw[1..] else raw;
                    try buf.appendSlice(allocator, " data-lang=\"");
                    try buf.appendSlice(allocator, lang);
                    try buf.appendSlice(allocator, "\"");
                } else if (std.mem.eql(u8, attr.key, "data-actor")) {
                    // Mount boundary: wrap child views with actor identity for message routing
                    var val_buf: [256]u8 = undefined;
                    var fbs = std.io.fixedBufferStream(&val_buf);
                    attr.val.format(fbs.writer());
                    const raw = fbs.getWritten();
                    const name = if (raw.len >= 2 and raw[0] == '"') raw[1 .. raw.len - 1] else raw;
                    try buf.appendSlice(allocator, " data-actor=\"");
                    try buf.appendSlice(allocator, name);
                    try buf.appendSlice(allocator, "\"");
                }
            }
            if (std.mem.eql(u8, node.tag, "divider") or std.mem.eql(u8, node.tag, "image")) {
                try buf.appendSlice(allocator, " />");
                return;
            }
            try buf.appendSlice(allocator, ">");
            for (node.children) |child| {
                try renderHtml(allocator, child, buf);
            }
            try buf.appendSlice(allocator, "</");
            try buf.appendSlice(allocator, tag);
            try buf.appendSlice(allocator, ">");
        },
        .string => |s| {
            for (s) |c| {
                switch (c) {
                    '<' => try buf.appendSlice(allocator, "&lt;"),
                    '>' => try buf.appendSlice(allocator, "&gt;"),
                    '&' => try buf.appendSlice(allocator, "&amp;"),
                    '"' => try buf.appendSlice(allocator, "&quot;"),
                    else => try buf.append(allocator, c),
                }
            }
        },
        .integer => |n| {
            var tmp: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&tmp, "{d}", .{n}) catch return;
            try buf.appendSlice(allocator, s);
        },
        .float => |f| {
            var tmp: [64]u8 = undefined;
            const s = std.fmt.bufPrint(&tmp, "{d}", .{f}) catch return;
            try buf.appendSlice(allocator, s);
        },
        .boolean => |b| try buf.appendSlice(allocator, if (b) "true" else "false"),
        .nil => {},
        else => {
            var tmp: [256]u8 = undefined;
            var fbs = std.io.fixedBufferStream(&tmp);
            val.format(fbs.writer());
            try buf.appendSlice(allocator, fbs.getWritten());
        },
    }
}

fn blimpTagToHtml(tag: []const u8) []const u8 {
    if (std.mem.eql(u8, tag, "stack")) return "div";
    if (std.mem.eql(u8, tag, "row")) return "div"; // gets data-row attr below
    if (std.mem.eql(u8, tag, "grid")) return "div";
    if (std.mem.eql(u8, tag, "text")) return "span";
    if (std.mem.eql(u8, tag, "heading")) return "h1";
    if (std.mem.eql(u8, tag, "bold")) return "strong";
    if (std.mem.eql(u8, tag, "italic")) return "em";
    if (std.mem.eql(u8, tag, "code")) return "code";
    if (std.mem.eql(u8, tag, "code_block")) return "pre";
    if (std.mem.eql(u8, tag, "blockquote")) return "blockquote";
    if (std.mem.eql(u8, tag, "divider")) return "hr";
    if (std.mem.eql(u8, tag, "list")) return "ul";
    if (std.mem.eql(u8, tag, "link")) return "a";
    if (std.mem.eql(u8, tag, "image")) return "img";
    if (std.mem.eql(u8, tag, "video")) return "video";
    if (std.mem.eql(u8, tag, "canvas")) return "canvas";
    if (std.mem.eql(u8, tag, "button")) return "button";
    if (std.mem.eql(u8, tag, "mount")) return "div"; // mount boundary renders as div with data-actor
    return "div";
}

/// tcp_listen(port: Int) -> Int  (server socket fd)
fn builtinTcpListen(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1 or args[0].* != .integer) return error.TypeError;
    const port: u16 = @intCast(@max(0, @min(65535, args[0].integer)));

    const sock = std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0) catch return error.NotSupported;
    // Allow port reuse so we can restart quickly
    const one: c_int = 1;
    _ = std.posix.setsockopt(sock, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, std.mem.asBytes(&one)) catch {};
    const addr = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, port);
    std.posix.bind(sock, &addr.any, addr.getOsSockLen()) catch return error.NotSupported;
    std.posix.listen(sock, 128) catch return error.NotSupported;

    const result = allocator.create(Value) catch return error.OutOfMemory;
    result.* = Value{ .integer = @intCast(sock) };
    return result;
}

/// tcp_accept(server_fd: Int) -> Int  (client socket fd, blocks)
fn builtinTcpAccept(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1 or args[0].* != .integer) return error.TypeError;
    const server_fd: std.posix.socket_t = @intCast(args[0].integer);
    var client_addr: std.posix.sockaddr = undefined;
    var addr_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);
    const client_fd = std.posix.accept(server_fd, &client_addr, &addr_len, 0) catch return error.NotSupported;
    const result = allocator.create(Value) catch return error.OutOfMemory;
    result.* = Value{ .integer = @intCast(client_fd) };
    return result;
}

/// tcp_read(fd: Int) -> String  (reads up to 64KB)
fn builtinTcpRead(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1 or args[0].* != .integer) return error.TypeError;
    const fd: std.posix.fd_t = @intCast(args[0].integer);
    var buf: [65536]u8 = undefined;
    const n = std.posix.read(fd, &buf) catch return error.NotSupported;
    const owned = allocator.dupe(u8, buf[0..n]) catch return error.OutOfMemory;
    const result = allocator.create(Value) catch return error.OutOfMemory;
    result.* = Value{ .string = owned };
    return result;
}

/// tcp_write(fd: Int, data: String) -> nil
fn builtinTcpWrite(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 2 or args[0].* != .integer or args[1].* != .string) return error.TypeError;
    const fd: std.posix.fd_t = @intCast(args[0].integer);
    _ = std.posix.write(fd, args[1].string) catch return error.NotSupported;
    const result = allocator.create(Value) catch return error.OutOfMemory;
    result.* = .nil;
    return result;
}

/// tcp_close(fd: Int) -> nil
fn builtinTcpClose(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1 or args[0].* != .integer) return error.TypeError;
    const fd: std.posix.fd_t = @intCast(args[0].integer);
    std.posix.close(fd);
    const result = allocator.create(Value) catch return error.OutOfMemory;
    result.* = .nil;
    return result;
}

test "type_of view_node returns :view_node" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const node = try alloc.create(Value);
    node.* = Value{ .view_node = .{ .tag = "text", .attrs = &.{}, .children = &.{} } };
    const args = try alloc.alloc(*const Value, 1);
    args[0] = node;
    const result = try builtinTypeOf(alloc, args);
    try std.testing.expect(result.eql(Value{ .atom = "view_node" }));
}

test "mount_root creates mount ViewNode with data-actor attr" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const name = try alloc.create(Value);
    name.* = Value{ .string = "Counter" };

    const child = try alloc.create(Value);
    child.* = Value{ .view_node = .{ .tag = "text", .attrs = &.{}, .children = &.{} } };

    const args = try alloc.alloc(*const Value, 2);
    args[0] = name;
    args[1] = child;

    const result = try viewMountRoot(alloc, args);
    try std.testing.expect(result.* == .view_node);
    try std.testing.expectEqualStrings("mount", result.view_node.tag);
    try std.testing.expectEqual(@as(usize, 1), result.view_node.attrs.len);
    try std.testing.expectEqualStrings("data-actor", result.view_node.attrs[0].key);
    try std.testing.expect(result.view_node.attrs[0].val.eql(Value{ .string = "Counter" }));
    try std.testing.expectEqual(@as(usize, 1), result.view_node.children.len);
}

test "mount_root rejects non-string name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const name = try alloc.create(Value);
    name.* = Value{ .integer = 42 };

    const child = try alloc.create(Value);
    child.* = Value{ .view_node = .{ .tag = "text", .attrs = &.{}, .children = &.{} } };

    const args = try alloc.alloc(*const Value, 2);
    args[0] = name;
    args[1] = child;

    const result = viewMountRoot(alloc, args);
    try std.testing.expectError(error.TypeError, result);
}

test "mount_root rejects non-view child" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const name = try alloc.create(Value);
    name.* = Value{ .string = "Counter" };

    const child = try alloc.create(Value);
    child.* = Value{ .string = "not a view" };

    const args = try alloc.alloc(*const Value, 2);
    args[0] = name;
    args[1] = child;

    const result = viewMountRoot(alloc, args);
    try std.testing.expectError(error.TypeError, result);
}

test "to_html renders mount as div with data-actor" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Build a mount node: mount_root("Counter", text("hello"))
    const text_str = try alloc.create(Value);
    text_str.* = Value{ .string = "hello" };
    const text_node = try alloc.create(Value);
    text_node.* = Value{ .view_node = .{
        .tag = "text",
        .attrs = &.{},
        .children = @as([]const *const Value, &.{text_str}),
    } };

    const actor_name = try alloc.create(Value);
    actor_name.* = Value{ .string = "Counter" };
    const mount_attrs = try alloc.alloc(ViewAttr, 1);
    mount_attrs[0] = .{ .key = "data-actor", .val = actor_name };
    const mount_children = try alloc.alloc(*const Value, 1);
    mount_children[0] = text_node;
    const mount_node = try alloc.create(Value);
    mount_node.* = Value{ .view_node = .{
        .tag = "mount",
        .attrs = mount_attrs,
        .children = mount_children,
    } };

    const html_args = try alloc.alloc(*const Value, 1);
    html_args[0] = mount_node;
    const result = try builtinToHtml(alloc, html_args);
    try std.testing.expectEqualStrings("<div data-actor=\"Counter\"><span>hello</span></div>", result.string);
}
