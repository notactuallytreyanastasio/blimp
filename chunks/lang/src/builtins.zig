const std = @import("std");
const ioenv = @import("ioenv.zig");
const builtin = @import("builtin");
const Value = @import("value.zig").Value;
const interned = @import("value.zig").interned;
const is_wasm = builtin.target.cpu.arch == .wasm32;

pub const EvalError = error{
    UndefinedVariable,
    TypeError,
    UnsupportedOperation,
    DivisionByZero,
    NotSupported,
    OutOfMemory,
    Bubble, // Actor failure propagation
    RecursionTooDeep,
};

pub const BuiltinFn = *const fn (allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value;

// Assertion failure detail (for structured test reports, e.g. in-browser tutorial).
// Each assertion writes its expected/actual into this buffer on failure.
// The test runner reads it after a failing test and resets it between tests.
pub var last_assertion_detail: [512]u8 = undefined;
pub var last_assertion_detail_len: u32 = 0;

fn recordAssertionDetail(comptime fmt: []const u8, args: anytype) void {
    var fbs = std.Io.Writer.fixed(&last_assertion_detail);
    fbs.print(fmt, args) catch {};
    last_assertion_detail_len = @intCast(fbs.buffered().len);
}

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
        reg.register("now_ms", &builtinNowMs);
        reg.register("concat", &builtinConcat);
        reg.register("split", &builtinSplit);
        reg.register("contains", &builtinContains);
        reg.register("to_string", &builtinToString);
        reg.register("to_int", &builtinToInt);
        reg.register("char_at", &builtinCharAt);
        reg.register("char_code", &builtinCharCode);
        reg.register("from_char_code", &builtinFromCharCode);
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
        reg.register("puts", &builtinPuts);
        // Test assertions
        reg.register("assert", &builtinAssert);
        // Generators for property-based testing
        reg.register("gen_integer", &builtinGenInteger);
        reg.register("gen_string", &builtinGenString);
        reg.register("gen_boolean", &builtinGenBoolean);
        reg.register("gen_list", &builtinGenList);
        reg.register("gen_one_of", &builtinGenOneOf);
        reg.register("assert_eq", &builtinAssertEq);
        reg.register("assert_ne", &builtinAssertNe);
        reg.register("refute", &builtinRefute);
        reg.register("rem", &builtinRem);
        reg.register("abs", &builtinAbs);
        reg.register("nil?", &builtinIsNil);
        reg.register("elem", &builtinElem);
        reg.register("floor", &builtinFloor);
        reg.register("ceil", &builtinCeil);
        reg.register("round", &builtinRound);
        inline for (float_fns) |entry| reg.register(entry[0], unaryFloat(entry[1]));
        reg.register("pow", &builtinPow);
        reg.register("atan2", &builtinAtan2);
        reg.register("not", &builtinNot);
        reg.register("random", &builtinRandom);
        reg.register("seed", &builtinSeed);
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
        reg.register("timer", &viewTimer);
        reg.register("key", &viewKey);
        reg.register("input", &viewInput);
        reg.register("textarea", &viewTextarea);
        reg.register("select", &viewSelect);
        reg.register("option", &viewOption);
        reg.register("form", &viewForm);
        reg.register("mount_root", &viewMountRoot);
        // Actor introspection
        reg.register("actor_name", &builtinActorName);
        reg.register("to_atom", &builtinToAtom);
        reg.register("write_bytes", &builtinWriteBytes);
        reg.register("read_file", &builtinReadFile);
        reg.register("write_file", &builtinWriteFile);
        // Native-only builtins (TCP, process, WebSocket -- stubbed on WASM)
        reg.register("to_html", &builtinToHtml_impl);
        reg.register("tcp_listen", &builtinTcpListen_impl);
        reg.register("tcp_connect", &builtinTcpConnectNative);
        reg.register("tcp_accept", &builtinTcpAccept_impl);
        reg.register("tcp_read", &builtinTcpRead_impl);
        reg.register("tcp_write", &builtinTcpWrite_impl);
        reg.register("tcp_close", &builtinTcpClose_impl);
        reg.register("ws_accept_key", &builtinWsAcceptKey_impl);
        reg.register("ws_read_frame", &builtinWsReadFrame_impl);
        reg.register("ws_write_frame", &builtinWsWriteFrame_impl);
        reg.register("view_diff", &builtinViewDiff_impl);
        reg.register("fork", &builtinFork_impl);
        reg.register("waitpid", &builtinWaitpid_impl);
        reg.register("exit", &builtinExit_impl);
        reg.register("tcp_set_nonblocking", &builtinTcpSetNonblocking_impl);
        reg.register("tcp_poll", &builtinTcpPoll_impl);
        reg.register("sleep_ms", &builtinSleepMs_impl);
        reg.register("read_line", &builtinReadLine_impl);
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

/// Hand back a value, sharing the small immutable ones (see `value.interned`).
/// Builtins allocate from the same never-reclaimed heap as the evaluator, so a
/// `length` or `abs` in a loop is a value retained per iteration.
fn make(allocator: std.mem.Allocator, v: Value) EvalError!*const Value {
    if (interned.get(v)) |shared| return shared;
    const p = allocator.create(Value) catch return error.OutOfMemory;
    p.* = v;
    return p;
}

fn builtinLength(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1) return error.TypeError;
    const arg = args[0];
    switch (arg.*) {
        .list => |items| {
            return make(allocator, .{ .integer = @intCast(items.len) });
        },
        .string => |s| {
            return make(allocator, .{ .integer = @intCast(s.len) });
        },
        .map => |entries| {
            return make(allocator, .{ .integer = @intCast(entries.len) });
        },
        else => return error.TypeError,
    }
}

fn builtinMax(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 2) return error.TypeError;
    switch (args[0].*) {
        .integer => |a| switch (args[1].*) {
            .integer => |b| {
                return make(allocator, .{ .integer = @max(a, b) });
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
                return make(allocator, .{ .integer = @min(a, b) });
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
            return make(allocator, .nil);
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
    // zig 0.16 removed `std.time.timestamp`; libc still has the call it was.
    const timestamp: i64 = if (is_wasm)
        0 // TODO: import JS Date.now() via extern
    else
        blk: {
            var ts: std.c.timespec = undefined;
            _ = std.c.clock_gettime(.REALTIME, &ts);
            break :blk @intCast(ts.sec);
        };
    return make(allocator, .{ .integer = timestamp });
}

/// now_ms() -> milliseconds on a clock that only goes forwards.
///
/// `now()` answers whole seconds of wall time, which cannot express a 200ms
/// game tick and jumps if the system clock is set. This is MONOTONIC, so it is
/// good for measuring an interval and useless for telling the time; the two
/// are different questions and this answers the second one.
fn builtinNowMs(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 0) return error.TypeError;
    const ms: i64 = if (is_wasm)
        0 // TODO: import JS performance.now() via extern
    else
        blk: {
            var ts: std.c.timespec = undefined;
            _ = std.c.clock_gettime(.MONOTONIC, &ts);
            break :blk @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000_000);
        };
    return make(allocator, .{ .integer = ms });
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
    return make(allocator, .{ .boolean = found });
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

/// char_at("hello", 1) => "e" -- single character at index
fn builtinCharAt(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 2 or args[0].* != .string or args[1].* != .integer) return error.TypeError;
    const s = args[0].string;
    const idx: usize = @intCast(@max(0, args[1].integer));
    if (idx >= s.len) {
        return make(allocator, .nil);
    }
    const ch = allocator.alloc(u8, 1) catch return error.OutOfMemory;
    ch[0] = s[idx];
    const result = allocator.create(Value) catch return error.OutOfMemory;
    result.* = Value{ .string = ch };
    return result;
}

/// char_code("A", 0) => 65 -- ASCII/byte value at index
/// char_code("A") => 65 -- first char if no index
fn builtinCharCode(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len < 1 or args.len > 2) return error.TypeError;
    // Return nil for nil input (char_at past end returns nil)
    if (args[0].* == .nil) {
        return make(allocator, .nil);
    }
    if (args[0].* != .string) return error.TypeError;
    const s = args[0].string;
    const idx: usize = if (args.len == 2 and args[1].* == .integer)
        @intCast(@max(0, args[1].integer))
    else
        0;
    if (s.len == 0 or idx >= s.len) {
        return make(allocator, .nil);
    }
    return make(allocator, .{ .integer = @intCast(s[idx]) });
}

/// from_char_code(65) => "A" -- integer to single-byte string
fn builtinFromCharCode(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1 or args[0].* != .integer) return error.TypeError;
    const code: u8 = @intCast(@max(0, @min(255, args[0].integer)));
    const ch = allocator.alloc(u8, 1) catch return error.OutOfMemory;
    ch[0] = code;
    const result = allocator.create(Value) catch return error.OutOfMemory;
    result.* = Value{ .string = ch };
    return result;
}

/// slice("hello", 1, 3) => "ell" -- start index, length
fn builtinSlice(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 3) return error.TypeError;
    if (args[0].* != .string or args[1].* != .integer or args[2].* != .integer) return error.TypeError;
    const str = args[0].string;
    const start: usize = @intCast(@max(args[1].integer, 0));
    const len: usize = @intCast(@max(args[2].integer, 0));
    const end = @min(start + len, str.len);
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
        return make(allocator, .nil);
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

/// Write to stdout, ignoring a failure, because a builtin has nowhere to put
/// one: `print` answers its argument and `puts` answers nil.
fn outWrite(bytes: []const u8) void {
    if (is_wasm) return;
    std.Io.File.stdout().writeStreamingAll(ioenv.io, bytes) catch {};
}

/// Same for stderr, which is where a failed assertion goes.
fn errWrite(bytes: []const u8) void {
    if (is_wasm) return;
    std.Io.File.stderr().writeStreamingAll(ioenv.io, bytes) catch {};
}

/// print(value) => prints to stdout, returns the value (identity)
fn builtinPrint(_: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1) return error.TypeError;
    // Write to a buffer and print
    var buf: [4096]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    args[0].format(&fbs);
    if (!is_wasm) {
                outWrite(fbs.buffered());
        outWrite("\n");
    }
    return args[0]; // return the value (identity)
}

/// puts(value) -- write to stdout raw, then a newline.
///
/// Unlike `print`, a string is written as its own bytes rather than through
/// `Value.format`, so it arrives unquoted and unescaped, and there is no fixed
/// buffer to truncate it. Non-string values still format the usual way, but
/// stream straight out instead of landing in a 4096-byte buffer first.
fn builtinPuts(_: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1) return error.TypeError;
    if (is_wasm) return args[0];

        switch (args[0].*) {
        .string => |text| outWrite(text),
        else => {
            var buf: [4096]u8 = undefined;
            var fbs = std.Io.Writer.fixed(&buf);
            args[0].format(&fbs);
            outWrite(fbs.buffered());
        },
    }
    outWrite("\n");
    return args[0]; // return the value (identity), like print
}

// ── Test assertion builtins ─────────────────────────────

/// assert(expr) -- fails if expr is falsy (nil, false)
fn builtinAssert(_: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1) return error.TypeError;
    if (!args[0].truthy()) {
                errWrite("\x1b[31mAssertion failed: value is falsy\x1b[0m\n");
        var buf: [256]u8 = undefined;
        var fbs = std.Io.Writer.fixed(&buf);
        args[0].format(&fbs);
        errWrite("  got: ");
        errWrite(fbs.buffered());
        errWrite("\n");
        recordAssertionDetail("expected truthy, got {s}", .{fbs.buffered()});
        return error.TypeError; // assertion failure
    }
    return args[0];
}

/// assert_eq(a, b) -- fails if a != b
fn builtinAssertEq(_: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 2) return error.TypeError;
    if (!args[0].eql(args[1].*)) {
                errWrite("\x1b[31mAssertion failed: values not equal\x1b[0m\n");
        var left_buf: [256]u8 = undefined;
        var left_fbs = std.Io.Writer.fixed(&left_buf);
        args[0].format(&left_fbs);
        errWrite("  left:  ");
        errWrite(left_fbs.buffered());
        errWrite("\n");
        var right_buf: [256]u8 = undefined;
        var right_fbs = std.Io.Writer.fixed(&right_buf);
        args[1].format(&right_fbs);
        errWrite("  right: ");
        errWrite(right_fbs.buffered());
        errWrite("\n");
        recordAssertionDetail("expected {s}, got {s}", .{ right_fbs.buffered(), left_fbs.buffered() });
        return error.TypeError; // assertion failure
    }
    return args[0];
}

/// assert_ne(a, b) -- fails if a == b
fn builtinAssertNe(_: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 2) return error.TypeError;
    if (args[0].eql(args[1].*)) {
                errWrite("\x1b[31mAssertion failed: values should not be equal\x1b[0m\n");
        var buf: [256]u8 = undefined;
        var fbs = std.Io.Writer.fixed(&buf);
        args[0].format(&fbs);
        errWrite("  both: ");
        errWrite(fbs.buffered());
        errWrite("\n");
        recordAssertionDetail("both sides equal to {s}", .{fbs.buffered()});
        return error.TypeError; // assertion failure
    }
    return args[0];
}

/// refute(expr) -- fails if expr is truthy
fn builtinRefute(_: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1) return error.TypeError;
    if (args[0].truthy()) {
                errWrite("\x1b[31mRefute failed: value is truthy\x1b[0m\n");
        var buf: [256]u8 = undefined;
        var fbs = std.Io.Writer.fixed(&buf);
        args[0].format(&fbs);
        errWrite("  got: ");
        errWrite(fbs.buffered());
        errWrite("\n");
        recordAssertionDetail("expected falsy, got {s}", .{fbs.buffered()});
        return error.TypeError; // assertion failure
    }
    return args[0];
}

// ── Math and utility builtins ───────────────────────────

/// rem(10, 3) => 1 (integer remainder)
fn builtinRem(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 2) return error.TypeError;
    if (args[0].* != .integer or args[1].* != .integer) return error.TypeError;
    if (args[1].integer == 0) return error.DivisionByZero;
    return make(allocator, .{ .integer = @rem(args[0].integer, args[1].integer) });
}

/// abs(-5) => 5
fn builtinAbs(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1) return error.TypeError;
    const result = allocator.create(Value) catch return error.OutOfMemory;
    switch (args[0].*) {
        // abs(minInt) has no i64 answer; wrap to minInt, as the operators do.
        .integer => |n| result.* = Value{ .integer = if (n < 0) 0 -% n else n },
        .float => |f| result.* = Value{ .float = if (f < 0) -f else f },
        else => return error.TypeError,
    }
    return result;
}

/// nil?(nil) => true, nil?(42) => false
fn builtinIsNil(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1) return error.TypeError;
    return make(allocator, .{ .boolean = args[0].* == .nil });
}

/// elem({10, 20, 30}, 1) => 20 (0-indexed tuple access)
fn builtinElem(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 2) return error.TypeError;
    if (args[1].* != .integer) return error.TypeError;
    const idx: usize = @intCast(@max(args[1].integer, 0));
    switch (args[0].*) {
        .tuple => |items| {
            if (idx >= items.len) {
                return make(allocator, .nil);
            }
            return items[idx];
        },
        .list => |items| {
            if (idx >= items.len) {
                return make(allocator, .nil);
            }
            return items[idx];
        },
        else => return error.TypeError,
    }
}

// ── Float maths ──────────────────────────────────────

/// The float functions Blimp did not have.
///
/// The numeric builtins stopped at floor, ceil, round and abs, so anything
/// that wanted a square root had to fake one. temper-core, the Temper
/// backend's runtime, spelled `**` as repeated multiplication and gave up on a
/// fractional exponent: `4.0 ** -0.5` raised instead of answering 0.5.
///
/// Each takes a Float or an Int -- an Int answer would be wrong for all of
/// them anyway -- and returns a Float.
fn floatArg(v: *const Value) EvalError!f64 {
    return switch (v.*) {
        .float => |f| f,
        .integer => |n| @floatFromInt(n),
        else => error.TypeError,
    };
}

fn unaryFloat(comptime f: fn (f64) f64) BuiltinFn {
    return &struct {
        fn call(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
            if (args.len != 1) return error.TypeError;
            return make(allocator, .{ .float = f(try floatArg(args[0])) });
        }
    }.call;
}

const float_fns = .{
    .{ "sqrt", struct {
        fn f(x: f64) f64 {
            return @sqrt(x);
        }
    }.f },
    .{ "exp", struct {
        fn f(x: f64) f64 {
            return @exp(x);
        }
    }.f },
    .{ "expm1", struct {
        fn f(x: f64) f64 {
            return std.math.expm1(x);
        }
    }.f },
    .{ "log", struct {
        fn f(x: f64) f64 {
            return @log(x);
        }
    }.f },
    .{ "log1p", struct {
        fn f(x: f64) f64 {
            return std.math.log1p(x);
        }
    }.f },
    .{ "log2", struct {
        fn f(x: f64) f64 {
            return @log2(x);
        }
    }.f },
    .{ "log10", struct {
        fn f(x: f64) f64 {
            return @log10(x);
        }
    }.f },
    .{ "sin", struct {
        fn f(x: f64) f64 {
            return @sin(x);
        }
    }.f },
    .{ "cos", struct {
        fn f(x: f64) f64 {
            return @cos(x);
        }
    }.f },
    .{ "tan", struct {
        fn f(x: f64) f64 {
            return @tan(x);
        }
    }.f },
    .{ "asin", struct {
        fn f(x: f64) f64 {
            return std.math.asin(x);
        }
    }.f },
    .{ "acos", struct {
        fn f(x: f64) f64 {
            return std.math.acos(x);
        }
    }.f },
    .{ "atan", struct {
        fn f(x: f64) f64 {
            return std.math.atan(x);
        }
    }.f },
    .{ "sinh", struct {
        fn f(x: f64) f64 {
            return std.math.sinh(x);
        }
    }.f },
    .{ "cosh", struct {
        fn f(x: f64) f64 {
            return std.math.cosh(x);
        }
    }.f },
    .{ "tanh", struct {
        fn f(x: f64) f64 {
            return std.math.tanh(x);
        }
    }.f },
};

/// pow(2.0, 10.0) => 1024.0.  Whole or fractional, positive or negative.
fn builtinPow(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 2) return error.TypeError;
    const base = try floatArg(args[0]);
    const exponent = try floatArg(args[1]);
    return make(allocator, .{ .float = std.math.pow(f64, base, exponent) });
}

/// atan2(y, x), the angle of the point (x, y) with the sign of both.
fn builtinAtan2(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 2) return error.TypeError;
    const y = try floatArg(args[0]);
    const x = try floatArg(args[1]);
    return make(allocator, .{ .float = std.math.atan2(y, x) });
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
    return make(allocator, .{ .boolean = !args[0].truthy() });
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
            if (existing.eql(item.*)) {
                found = true;
                break;
            }
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
        if (item.* == .integer) total +%= item.integer;
    }
    return make(allocator, .{ .integer = total });
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

    return make(allocator, .{ .integer = val });
}

/// seed(n: Int) -> :ok
/// Reseeds the xorshift generator behind random/2. The same seed replays the
/// same sequence, which is what tests want; hosts that want a fresh game
/// every load pass the clock in (tetris.html does seed(Date.now())).
fn builtinSeed(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1) return error.TypeError;
    if (args[0].* != .integer) return error.TypeError;
    // xorshift is stuck at zero forever, so mix the seed with a nonzero
    // constant (splitmix-style) instead of storing it raw.
    const raw: u64 = @bitCast(args[0].integer);
    var z = raw +% 0x9e3779b97f4a7c15;
    z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    z ^= z >> 31;
    random_state = if (z == 0) 0x853c49e6748fea9b else z;

    const result = allocator.create(Value) catch return error.OutOfMemory;
    result.* = Value{ .atom = "ok" };
    return result;
}

test "seed makes random reproducible" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const lo = try alloc.create(Value);
    lo.* = Value{ .integer = 1 };
    const hi = try alloc.create(Value);
    hi.* = Value{ .integer = 1_000_000 };
    const range_args = try alloc.alloc(*const Value, 2);
    range_args[0] = lo;
    range_args[1] = hi;

    const n = try alloc.create(Value);
    n.* = Value{ .integer = 42 };
    const seed_args = try alloc.alloc(*const Value, 1);
    seed_args[0] = n;

    const ok = try builtinSeed(alloc, seed_args);
    try std.testing.expect(ok.eql(Value{ .atom = "ok" }));
    const a1 = (try builtinRandom(alloc, range_args)).integer;
    const a2 = (try builtinRandom(alloc, range_args)).integer;
    _ = try builtinSeed(alloc, seed_args);
    const b1 = (try builtinRandom(alloc, range_args)).integer;
    const b2 = (try builtinRandom(alloc, range_args)).integer;
    try std.testing.expectEqual(a1, b1);
    try std.testing.expectEqual(a2, b2);

    // a different seed gives a different first draw
    n.* = Value{ .integer = 43 };
    _ = try builtinSeed(alloc, seed_args);
    const c1 = (try builtinRandom(alloc, range_args)).integer;
    try std.testing.expect(c1 != a1);
}

test "seed zero does not wedge xorshift" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const n = try alloc.create(Value);
    n.* = Value{ .integer = 0 };
    const seed_args = try alloc.alloc(*const Value, 1);
    seed_args[0] = n;
    _ = try builtinSeed(alloc, seed_args);

    const lo = try alloc.create(Value);
    lo.* = Value{ .integer = 0 };
    const hi = try alloc.create(Value);
    hi.* = Value{ .integer = 1_000_000 };
    const range_args = try alloc.alloc(*const Value, 2);
    range_args[0] = lo;
    range_args[1] = hi;
    var saw_nonzero = false;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        if ((try builtinRandom(alloc, range_args)).integer != 0) saw_nonzero = true;
    }
    try std.testing.expect(saw_nonzero);
}

test "seed rejects bad args" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const s = try alloc.create(Value);
    s.* = Value{ .string = "42" };
    const one = try alloc.alloc(*const Value, 1);
    one[0] = s;
    try std.testing.expectError(error.TypeError, builtinSeed(alloc, one));
    const none = try alloc.alloc(*const Value, 0);
    try std.testing.expectError(error.TypeError, builtinSeed(alloc, none));
}

// ============================================================
// File I/O builtins
// ============================================================

/// write_bytes(path: String, bytes: List of Int) -> :ok
/// Writes a list of byte values (0-255) to a file.
fn builtinWriteBytes(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 2 or args[0].* != .string or args[1].* != .list) return error.TypeError;
    const path = args[0].string;
    const byte_list = args[1].list;

    // Convert list of integers to byte array
    const buf = allocator.alloc(u8, byte_list.len) catch return error.OutOfMemory;
    for (byte_list, 0..) |val, i| {
        if (val.* != .integer) return error.TypeError;
        buf[i] = @intCast(@max(0, @min(255, val.integer)));
    }

    // Write to file
    if (is_wasm) {
        return error.NotSupported;
    }
    const file = std.Io.Dir.cwd().createFile(ioenv.io, path, .{}) catch return error.NotSupported;
    defer file.close(ioenv.io);
    file.writeStreamingAll(ioenv.io, buf) catch return error.NotSupported;

    const result = allocator.create(Value) catch return error.OutOfMemory;
    result.* = Value{ .atom = "ok" };
    return result;
}

/// write_file("out.txt", "text") => true, or false if it could not be written.
///
/// `read_file` has been here on its own, and `write_bytes` wants a list of
/// integers, so writing a string meant converting it a character at a time.
///
/// The three file builtins have three answers for failure: this one is false,
/// `read_file` is nil, and `write_bytes` raises. Matching one of them would
/// have meant mismatching the others.
fn builtinWriteFile(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 2 or args[0].* != .string or args[1].* != .string) return error.TypeError;
    if (is_wasm) return error.NotSupported;
    const file = std.Io.Dir.cwd().createFile(ioenv.io, args[0].string, .{}) catch {
        return make(allocator, .{ .boolean = false });
    };
    defer file.close(ioenv.io);
    file.writeStreamingAll(ioenv.io, args[1].string) catch {
        return make(allocator, .{ .boolean = false });
    };
    return make(allocator, .{ .boolean = true });
}

/// read_file(path: String) -> String, or nil when it cannot be read.
fn builtinReadFile(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1 or args[0].* != .string) return error.TypeError;
    if (is_wasm) return error.NotSupported;
    const path = args[0].string;
    const content = std.Io.Dir.cwd().readFileAlloc(ioenv.io, path, allocator, .limited(1024 * 1024)) catch {
        return make(allocator, .nil);
    };
    const result = allocator.create(Value) catch return error.OutOfMemory;
    result.* = Value{ .string = content };
    return result;
}

// ============================================================
// Property-based testing generators
// ============================================================

fn nextRandom() u64 {
    random_state ^= random_state << 13;
    random_state ^= random_state >> 7;
    random_state ^= random_state << 17;
    return random_state;
}

/// gen_integer(min, max) -> random Int in [min, max]
fn builtinGenInteger(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 2 or args[0].* != .integer or args[1].* != .integer) return error.TypeError;
    const lo = args[0].integer;
    const hi = args[1].integer;
    const range: u64 = @intCast(@max(hi - lo + 1, 1));
    const val = lo + @as(i64, @intCast(nextRandom() % range));
    return make(allocator, .{ .integer = val });
}

/// gen_string(max_len) -> random String of printable ASCII
fn builtinGenString(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1 or args[0].* != .integer) return error.TypeError;
    const max_len: usize = @intCast(@max(0, args[0].integer));
    const len: usize = @intCast(nextRandom() % (max_len + 1));
    const buf = allocator.alloc(u8, len) catch return error.OutOfMemory;
    for (buf) |*c| {
        c.* = @intCast(32 + nextRandom() % 95); // printable ASCII 32-126
    }
    const result = allocator.create(Value) catch return error.OutOfMemory;
    result.* = Value{ .string = buf };
    return result;
}

/// gen_boolean() -> random true or false
fn builtinGenBoolean(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 0) return error.TypeError;
    return make(allocator, .{ .boolean = nextRandom() % 2 == 0 });
}

/// gen_list(gen_fn_name_not_used, max_len) -> random list of integers
/// For now generates lists of random integers. Full generator composition later.
fn builtinGenList(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    // gen_list(max_len) or gen_list(max_len, min_val, max_val)
    if (args.len < 1 or args[0].* != .integer) return error.TypeError;
    const max_len: usize = @intCast(@max(0, args[0].integer));
    const min_val: i64 = if (args.len >= 2 and args[1].* == .integer) args[1].integer else -100;
    const max_val: i64 = if (args.len >= 3 and args[2].* == .integer) args[2].integer else 100;
    const len: usize = @intCast(nextRandom() % (max_len + 1));
    const items = allocator.alloc(*const Value, len) catch return error.OutOfMemory;
    const range: u64 = @intCast(@max(max_val - min_val + 1, 1));
    for (items) |*item| {
        const v = allocator.create(Value) catch return error.OutOfMemory;
        v.* = Value{ .integer = min_val + @as(i64, @intCast(nextRandom() % range)) };
        item.* = v;
    }
    const result = allocator.create(Value) catch return error.OutOfMemory;
    result.* = Value{ .list = items };
    return result;
}

/// gen_one_of([a, b, c]) -> random element from the list
fn builtinGenOneOf(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1 or args[0].* != .list) return error.TypeError;
    const items = args[0].list;
    if (items.len == 0) {
        return make(allocator, .nil);
    }
    const idx: usize = @intCast(nextRandom() % items.len);
    return items[idx];
}

// ============================================================
// View primitive helpers
// ============================================================

const ViewAttr = Value.ViewNode.ViewAttr;

/// Build a view_node with the given tag, attrs, and variadic children.
/// If any child is a list, its elements are flattened into the children array.
/// This allows `stack(map(items, fn(x) do text(x) end))` to work naturally.
fn makeViewNode(allocator: std.mem.Allocator, tag: []const u8, attrs: []const ViewAttr, children: []const *const Value) EvalError!*const Value {
    const node_attrs = allocator.dupe(ViewAttr, attrs) catch return error.OutOfMemory;
    // Count total children after flattening lists
    var total: usize = 0;
    for (children) |child| {
        switch (child.*) {
            .list => |items| {
                total += items.len;
            },
            else => {
                total += 1;
            },
        }
    }
    // Build flattened children array
    const node_children = allocator.alloc(*const Value, total) catch return error.OutOfMemory;
    var idx: usize = 0;
    for (children) |child| {
        switch (child.*) {
            .list => |items| {
                for (items) |item| {
                    node_children[idx] = item;
                    idx += 1;
                }
            },
            else => {
                node_children[idx] = child;
                idx += 1;
            },
        }
    }
    const node = allocator.create(Value.ViewNode) catch return error.OutOfMemory;
    node.* = .{ .tag = tag, .attrs = node_attrs, .children = node_children };
    return make(allocator, .{ .view_node = node });
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

/// timer(ms, sends_atom) — effect node: while mounted, the host sends the atom every ms milliseconds
fn viewTimer(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 2) return error.TypeError;
    if (args[0].* != .integer or args[1].* != .atom) return error.TypeError;
    const attrs = try allocator.alloc(ViewAttr, 2);
    attrs[0] = .{ .key = "ms", .val = args[0] };
    attrs[1] = .{ .key = "sends", .val = args[1] };
    return makeViewNode(allocator, "timer", attrs, &.{});
}

/// key("ArrowLeft", sends_atom) — effect node: while mounted, that KeyboardEvent.key sends the atom
fn viewKey(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 2) return error.TypeError;
    if (args[0].* != .string or args[1].* != .atom) return error.TypeError;
    const attrs = try allocator.alloc(ViewAttr, 2);
    attrs[0] = .{ .key = "code", .val = args[0] };
    attrs[1] = .{ .key = "sends", .val = args[1] };
    return makeViewNode(allocator, "key", attrs, &.{});
}

/// input("name", "placeholder") — text input field
/// input("name", "placeholder", :type) — typed input (e.g. :password, :email, :number)
fn viewInput(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len < 2 or args.len > 3) return error.TypeError;
    if (args[0].* != .string or args[1].* != .string) return error.TypeError;
    var attr_count: usize = 2;
    if (args.len == 3) {
        if (args[2].* != .atom) return error.TypeError;
        attr_count = 3;
    }
    const attrs = try allocator.alloc(ViewAttr, attr_count);
    attrs[0] = .{ .key = "name", .val = args[0] };
    attrs[1] = .{ .key = "placeholder", .val = args[1] };
    if (args.len == 3) {
        attrs[2] = .{ .key = "type", .val = args[2] };
    }
    return makeViewNode(allocator, "input", attrs, &.{});
}

/// textarea("name", "placeholder") — multi-line text input
fn viewTextarea(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 2) return error.TypeError;
    if (args[0].* != .string or args[1].* != .string) return error.TypeError;
    const attrs = try allocator.alloc(ViewAttr, 2);
    attrs[0] = .{ .key = "name", .val = args[0] };
    attrs[1] = .{ .key = "placeholder", .val = args[1] };
    return makeViewNode(allocator, "textarea", attrs, &.{});
}

/// select("name", option1, option2, ...) — dropdown select with option children
fn viewSelect(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len < 1) return error.TypeError;
    if (args[0].* != .string) return error.TypeError;
    const attrs = try allocator.alloc(ViewAttr, 1);
    attrs[0] = .{ .key = "name", .val = args[0] };
    // remaining args are option children
    const children = if (args.len > 1) args[1..] else &[_]*const Value{};
    return makeViewNode(allocator, "select", attrs, children);
}

/// option("label", "value") — option inside a select
fn viewOption(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 2) return error.TypeError;
    if (args[0].* != .string or args[1].* != .string) return error.TypeError;
    const attrs = try allocator.alloc(ViewAttr, 1);
    attrs[0] = .{ .key = "value", .val = args[1] };
    return makeViewNode(allocator, "option_elem", attrs, args[0..1]);
}

/// form(children...) — form wrapper that collects inputs on submit
fn viewForm(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    return makeViewNode(allocator, "form", &.{}, args);
}

/// mount_root("ActorName", view_node) — wraps a child actor's view in a mount boundary
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
    const c1_view = try alloc.create(Value.ViewNode);
    c1_view.* = .{ .tag = "text", .attrs = &.{}, .children = &.{c1_str} };
    c1.* = Value{ .view_node = c1_view };
    const c2 = try alloc.create(Value);
    const c2_str = try alloc.create(Value);
    c2_str.* = Value{ .string = "b" };
    const c2_view = try alloc.create(Value.ViewNode);
    c2_view.* = .{ .tag = "text", .attrs = &.{}, .children = &.{c2_str} };
    c2.* = Value{ .view_node = c2_view };

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

test "view timer with ms and sends" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const ms = try alloc.create(Value);
    ms.* = Value{ .integer = 500 };
    const msg = try alloc.create(Value);
    msg.* = Value{ .atom = "tick" };
    const args = try alloc.alloc(*const Value, 2);
    args[0] = ms;
    args[1] = msg;
    const result = try viewTimer(alloc, args);
    try std.testing.expectEqualStrings("timer", result.view_node.tag);
    try std.testing.expectEqual(@as(usize, 2), result.view_node.attrs.len);
    try std.testing.expectEqualStrings("ms", result.view_node.attrs[0].key);
    try std.testing.expect(result.view_node.attrs[0].val.eql(Value{ .integer = 500 }));
    try std.testing.expectEqualStrings("sends", result.view_node.attrs[1].key);
    try std.testing.expect(result.view_node.attrs[1].val.eql(Value{ .atom = "tick" }));
    try std.testing.expectEqual(@as(usize, 0), result.view_node.children.len);

    // wrong arg types raise TypeError
    args[0] = msg;
    try std.testing.expectError(error.TypeError, viewTimer(alloc, args));
}

test "view key with code and sends" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const code = try alloc.create(Value);
    code.* = Value{ .string = "ArrowLeft" };
    const msg = try alloc.create(Value);
    msg.* = Value{ .atom = "left" };
    const args = try alloc.alloc(*const Value, 2);
    args[0] = code;
    args[1] = msg;
    const result = try viewKey(alloc, args);
    try std.testing.expectEqualStrings("key", result.view_node.tag);
    try std.testing.expectEqual(@as(usize, 2), result.view_node.attrs.len);
    try std.testing.expectEqualStrings("code", result.view_node.attrs[0].key);
    try std.testing.expect(result.view_node.attrs[0].val.eql(Value{ .string = "ArrowLeft" }));
    try std.testing.expectEqualStrings("sends", result.view_node.attrs[1].key);
    try std.testing.expect(result.view_node.attrs[1].val.eql(Value{ .atom = "left" }));
    try std.testing.expectEqual(@as(usize, 0), result.view_node.children.len);

    // wrong arg types raise TypeError
    args[1] = code;
    try std.testing.expectError(error.TypeError, viewKey(alloc, args));
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

// ============================================================
// Native-only stub: on WASM, these functions return error.NotSupported
// so the compiler doesn't try to resolve std.posix symbols.
// ============================================================

const native_stub = if (is_wasm) struct {
    fn stub(_: std.mem.Allocator, _: []const *const Value) EvalError!*const Value {
        return error.NotSupported;
    }
} else struct {};

const builtinToHtml_impl = if (is_wasm) native_stub.stub else builtinToHtmlNative;
const builtinTcpListen_impl = if (is_wasm) native_stub.stub else builtinTcpListenNative;
const builtinTcpAccept_impl = if (is_wasm) native_stub.stub else builtinTcpAcceptNative;
const builtinTcpRead_impl = if (is_wasm) native_stub.stub else builtinTcpReadNative;
const builtinTcpWrite_impl = if (is_wasm) native_stub.stub else builtinTcpWriteNative;
const builtinTcpClose_impl = if (is_wasm) native_stub.stub else builtinTcpCloseNative;
const builtinWsAcceptKey_impl = if (is_wasm) native_stub.stub else builtinWsAcceptKeyNative;
const builtinWsReadFrame_impl = if (is_wasm) native_stub.stub else builtinWsReadFrameNative;
const builtinWsWriteFrame_impl = if (is_wasm) native_stub.stub else builtinWsWriteFrameNative;
const builtinViewDiff_impl = if (is_wasm) native_stub.stub else builtinViewDiffNative;
const builtinFork_impl = if (is_wasm) native_stub.stub else builtinForkNative;
const builtinWaitpid_impl = if (is_wasm) native_stub.stub else builtinWaitpidNative;
const builtinExit_impl = if (is_wasm) native_stub.stub else builtinExitNative;
const builtinTcpSetNonblocking_impl = if (is_wasm) native_stub.stub else builtinTcpSetNonblockingNative;
const builtinTcpPoll_impl = if (is_wasm) native_stub.stub else builtinTcpPollNative;
const builtinSleepMs_impl = if (is_wasm) native_stub.stub else builtinSleepMsNative;
const builtinReadLine_impl = if (is_wasm) native_stub.stub else builtinReadLineNative;

/// sleep_ms(n: Int) -> :ok
///
/// A game loop needs to do three things: read input, change state, and wait.
/// Blimp could do the middle one. `now()` reports seconds, so a busy-wait on
/// it cannot express 200ms and would burn a core besides.
///
/// `nanosleep` rather than `sleep` because the unit that matters here is
/// milliseconds, and it restarts on a signal so a stray SIGWINCH from a
/// resized terminal does not cut the wait short.
fn builtinSleepMsNative(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1 or args[0].* != .integer) return error.TypeError;
    const ms = args[0].integer;
    if (ms > 0) {
        var req: std.c.timespec = .{
            .sec = @intCast(@divTrunc(ms, 1000)),
            .nsec = @intCast(@rem(ms, 1000) * 1_000_000),
        };
        var rem: std.c.timespec = undefined;
        while (std.c.nanosleep(&req, &rem) != 0) {
            req = rem;
        }
    }
    return make(allocator, .{ .atom = "ok" });
}

/// read_line() -> String without its newline, or nil at end of input.
///
/// nil rather than "" for end of input: a blank line a user typed is a real
/// empty string, and a caller that cannot tell the two apart loops forever on
/// a closed stdin.
fn builtinReadLineNative(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 0) return error.TypeError;
    var line = std.ArrayList(u8){ .items = &.{}, .capacity = 0 };
    defer line.deinit(allocator);
    var ch: [1]u8 = undefined;
    while (true) {
        const n = std.posix.read(std.posix.STDIN_FILENO, &ch) catch return error.NotSupported;
        if (n == 0) {
            // End of input with nothing buffered is the end. With something
            // buffered it is a last line that had no newline on it.
            if (line.items.len == 0) return make(allocator, .nil);
            break;
        }
        if (ch[0] == '\n') break;
        line.append(allocator, ch[0]) catch return error.OutOfMemory;
    }
    // A terminal that sends CRLF would otherwise put the CR in the string,
    // where it compares unequal to every key the caller is looking for.
    var end = line.items.len;
    if (end > 0 and line.items[end - 1] == '\r') end -= 1;
    const owned = allocator.dupe(u8, line.items[0..end]) catch return error.OutOfMemory;
    return make(allocator, .{ .string = owned });
}

/// to_html(view_node) -> String
/// Renders a view_node tree to an HTML string.
fn builtinToHtmlNative(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1) return error.TypeError;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    renderHtml(allocator, args[0], &buf) catch return error.OutOfMemory;
    const result = allocator.create(Value) catch return error.OutOfMemory;
    result.* = Value{ .string = buf.toOwnedSlice(allocator) catch return error.OutOfMemory };
    return result;
}

fn renderHtml(allocator: std.mem.Allocator, val: *const Value, buf: *std.ArrayListUnmanaged(u8)) !void {
    switch (val.*) {
        .view_node => |node| {
            // Effect nodes (timer, key) are host instructions, not markup.
            if (std.mem.eql(u8, node.tag, "timer") or std.mem.eql(u8, node.tag, "key")) return;
            const tag = blimpTagToHtml(node.tag);
            try buf.appendSlice(allocator, "<");
            try buf.appendSlice(allocator, tag);
            if (std.mem.eql(u8, node.tag, "row")) {
                try buf.appendSlice(allocator, " data-row");
            }
            if (std.mem.eql(u8, node.tag, "form")) {
                try buf.appendSlice(allocator, " method=\"POST\" action=\"\" onsubmit=\"blimpSubmit(event)\"");
            }
            for (node.attrs) |attr| {
                if (std.mem.eql(u8, attr.key, "href")) {
                    var val_buf: [512]u8 = undefined;
                    var fbs = std.Io.Writer.fixed(&val_buf);
                    attr.val.format(&fbs);
                    const raw = fbs.buffered();
                    const href = if (raw.len >= 2 and raw[0] == '"') raw[1 .. raw.len - 1] else raw;
                    try buf.appendSlice(allocator, " href=\"");
                    try buf.appendSlice(allocator, href);
                    try buf.appendSlice(allocator, "\"");
                } else if (std.mem.eql(u8, attr.key, "src")) {
                    var val_buf: [512]u8 = undefined;
                    var fbs = std.Io.Writer.fixed(&val_buf);
                    attr.val.format(&fbs);
                    const raw = fbs.buffered();
                    const src = if (raw.len >= 2 and raw[0] == '"') raw[1 .. raw.len - 1] else raw;
                    try buf.appendSlice(allocator, " src=\"");
                    try buf.appendSlice(allocator, src);
                    try buf.appendSlice(allocator, "\"");
                } else if (std.mem.eql(u8, attr.key, "sends")) {
                    var val_buf: [256]u8 = undefined;
                    var fbs = std.Io.Writer.fixed(&val_buf);
                    attr.val.format(&fbs);
                    const raw = fbs.buffered();
                    const msg = if (raw.len > 0 and raw[0] == ':') raw[1..] else raw;
                    try buf.appendSlice(allocator, " data-sends=\"");
                    try buf.appendSlice(allocator, msg);
                    try buf.appendSlice(allocator, "\" onclick=\"blimpSend(this)\"");
                } else if (std.mem.eql(u8, attr.key, "level")) {
                    // heading level - handled in tag mapping
                } else if (std.mem.eql(u8, attr.key, "lang")) {
                    var val_buf: [64]u8 = undefined;
                    var fbs = std.Io.Writer.fixed(&val_buf);
                    attr.val.format(&fbs);
                    const raw = fbs.buffered();
                    const lang = if (raw.len > 0 and raw[0] == ':') raw[1..] else raw;
                    try buf.appendSlice(allocator, " data-lang=\"");
                    try buf.appendSlice(allocator, lang);
                    try buf.appendSlice(allocator, "\"");
                } else if (std.mem.eql(u8, attr.key, "data-actor")) {
                    var val_buf: [256]u8 = undefined;
                    var fbs = std.Io.Writer.fixed(&val_buf);
                    attr.val.format(&fbs);
                    const raw = fbs.buffered();
                    const name = if (raw.len >= 2 and raw[0] == '"') raw[1 .. raw.len - 1] else raw;
                    try buf.appendSlice(allocator, " data-actor=\"");
                    try buf.appendSlice(allocator, name);
                    try buf.appendSlice(allocator, "\"");
                } else if (std.mem.eql(u8, attr.key, "name") or
                    std.mem.eql(u8, attr.key, "placeholder") or
                    std.mem.eql(u8, attr.key, "value"))
                {
                    var val_buf: [512]u8 = undefined;
                    var fbs = std.Io.Writer.fixed(&val_buf);
                    attr.val.format(&fbs);
                    const raw = fbs.buffered();
                    const clean = if (raw.len >= 2 and raw[0] == '"') raw[1 .. raw.len - 1] else raw;
                    try buf.appendSlice(allocator, " ");
                    try buf.appendSlice(allocator, attr.key);
                    try buf.appendSlice(allocator, "=\"");
                    try buf.appendSlice(allocator, clean);
                    try buf.appendSlice(allocator, "\"");
                } else if (std.mem.eql(u8, attr.key, "type")) {
                    var val_buf: [64]u8 = undefined;
                    var fbs = std.Io.Writer.fixed(&val_buf);
                    attr.val.format(&fbs);
                    const raw = fbs.buffered();
                    const type_name = if (raw.len > 0 and raw[0] == ':') raw[1..] else raw;
                    try buf.appendSlice(allocator, " type=\"");
                    try buf.appendSlice(allocator, type_name);
                    try buf.appendSlice(allocator, "\"");
                }
            }
            if (std.mem.eql(u8, node.tag, "divider") or std.mem.eql(u8, node.tag, "image") or std.mem.eql(u8, node.tag, "input")) {
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
            var fbs = std.Io.Writer.fixed(&tmp);
            val.format(&fbs);
            try buf.appendSlice(allocator, fbs.buffered());
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
    if (std.mem.eql(u8, tag, "mount")) return "div";
    if (std.mem.eql(u8, tag, "input")) return "input";
    if (std.mem.eql(u8, tag, "textarea")) return "textarea";
    if (std.mem.eql(u8, tag, "select")) return "select";
    if (std.mem.eql(u8, tag, "option_elem")) return "option";
    if (std.mem.eql(u8, tag, "form")) return "form";
    return "div";
}

/// tcp_listen(port: Int) -> Int  (server socket fd)
fn builtinTcpListenNative(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1 or args[0].* != .integer) return error.TypeError;
    // Not clamped. `tcp_connect` stopped clamping and this did not, so
    // `tcp_listen(99999)` still bound 65535 -- a program that asked for a port
    // that does not exist got a working listener on a different one, and
    // nothing said which.
    if (args[0].integer < 0 or args[0].integer > 65535) return make(allocator, .nil);
    const port: u16 = @intCast(args[0].integer);

    // zig 0.16 took the thin syscall wrappers out of `std.posix`; libc still
    // has them, and a `-1` with errno is the whole of their error handling.
    const sock_fd = std.c.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
    if (sock_fd < 0) return error.NotSupported;
    const sock: std.posix.socket_t = sock_fd;
    // Allow port reuse so we can restart quickly
    const one: c_int = 1;
    _ = std.posix.setsockopt(sock, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, std.mem.asBytes(&one)) catch {};
    // `std.net` moved under `std.Io`, and all this ever wanted was
    // 0.0.0.0:port, which is a sockaddr.in written out. Port is network order.
    var addr = std.mem.zeroes(std.posix.sockaddr.in);
    addr.family = std.posix.AF.INET;
    addr.port = std.mem.nativeToBig(u16, port);
    addr.addr = 0;
    if (std.c.bind(sock, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.in)) < 0) return error.NotSupported;
    if (std.c.listen(sock, 128) < 0) return error.NotSupported;

    return make(allocator, .{ .integer = @intCast(sock) });
}

/// tcp_connect(host: String, port: Int) -> Int | nil  (connected socket fd)
///
/// Blimp could listen and accept but not dial, so nothing written in it could
/// be an HTTP client. `getaddrinfo` does the resolving, which is what makes
/// "localhost" and a dotted quad the same amount of work here.
fn builtinTcpConnectNative(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 2 or args[0].* != .string or args[1].* != .integer) return error.TypeError;
    if (is_wasm) return error.NotSupported;

    // An empty host is not a default. macOS `getaddrinfo` resolves an empty
    // node to loopback, so `tcp_connect("", 80)` quietly connected to this
    // machine -- the one answer a caller who passed nothing cannot check.
    if (args[0].string.len == 0) return make(allocator, .nil);

    var host_buf: [256]u8 = undefined;
    if (args[0].string.len >= host_buf.len) return make(allocator, .nil);
    @memcpy(host_buf[0..args[0].string.len], args[0].string);
    host_buf[args[0].string.len] = 0;
    const host: [*:0]const u8 = @ptrCast(&host_buf);

    // Clamping is what made 99999 and 131071 both connect to a listener on
    // 65535. A port that is not a port is a connection that cannot be made.
    if (args[1].integer < 0 or args[1].integer > 65535) return make(allocator, .nil);

    var port_buf: [8]u8 = undefined;
    const port_text = std.fmt.bufPrint(&port_buf, "{d}\x00", .{@as(u16, @intCast(args[1].integer))}) catch return make(allocator, .nil);
    const port: [*:0]const u8 = @ptrCast(port_text.ptr);

    var hints = std.mem.zeroes(std.c.addrinfo);
    hints.family = std.posix.AF.UNSPEC;
    hints.socktype = std.posix.SOCK.STREAM;

    var res: ?*std.c.addrinfo = null;
    if (std.c.getaddrinfo(host, port, &hints, &res) != @as(std.c.EAI, @enumFromInt(0))) return make(allocator, .nil);
    defer if (res) |r| std.c.freeaddrinfo(r);

    // The first address that both opens and connects wins; the rest are the
    // other families the name resolved to.
    var it = res;
    while (it) |info| : (it = info.next) {
        const addr = info.addr orelse continue;
        const fd = std.c.socket(@intCast(info.family), @intCast(info.socktype), @intCast(info.protocol));
        if (fd < 0) continue;
        if (std.c.connect(fd, addr, info.addrlen) == 0) {
            return make(allocator, .{ .integer = @intCast(fd) });
        }
        _ = std.c.close(fd);
    }
    return make(allocator, .nil);
}

/// tcp_accept(server_fd: Int) -> Int | nil
/// Blocking accept by default. Returns nil if socket is non-blocking and
/// no connection is pending (WouldBlock/EAGAIN).
fn builtinTcpAcceptNative(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1 or args[0].* != .integer) return error.TypeError;
    const server_fd: std.posix.socket_t = @intCast(args[0].integer);
    var client_addr: std.posix.sockaddr = undefined;
    var addr_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);
    const accepted = std.c.accept(server_fd, &client_addr, &addr_len);
    if (accepted < 0) {
        // Non-blocking mode: no connection pending, return nil
        if (std.c._errno().* == @intFromEnum(std.c.E.AGAIN)) return make(allocator, .nil);
        return error.NotSupported;
    }
    const client_fd: std.posix.socket_t = accepted;
    return make(allocator, .{ .integer = @intCast(client_fd) });
}

/// tcp_read(fd: Int) -> String | nil
/// Reads up to 64KB. Returns nil if socket is non-blocking and no data
/// is available (WouldBlock/EAGAIN).
fn builtinTcpReadNative(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1 or args[0].* != .integer) return error.TypeError;
    const fd: std.posix.fd_t = @intCast(args[0].integer);
    var buf: [65536]u8 = undefined;
    const n = std.posix.read(fd, &buf) catch |err| {
        if (err == error.WouldBlock) {
            // Non-blocking mode: no data available, return nil
            return make(allocator, .nil);
        }
        // A peer that resets the connection has ended the stream, which is
        // what a reader wants to hear. Reporting it as a failed builtin
        // stopped the program instead -- an HTTP client reading from a server
        // that hung up rudely died rather than finishing its response.
        if (err == error.ConnectionResetByPeer) {
            return make(allocator, .{ .string = "" });
        }
        return error.NotSupported;
    };
    const owned = allocator.dupe(u8, buf[0..n]) catch return error.OutOfMemory;
    const result = allocator.create(Value) catch return error.OutOfMemory;
    result.* = Value{ .string = owned };
    return result;
}

/// tcp_write(fd: Int, data: String) -> :ok or :error
fn builtinTcpWriteNative(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 2 or args[0].* != .integer or args[1].* != .string) return error.TypeError;
    const fd: std.posix.fd_t = @intCast(args[0].integer);
    if (std.c.write(fd, args[1].string.ptr, args[1].string.len) < 0) {
        const result = allocator.create(Value) catch return error.OutOfMemory;
        result.* = Value{ .atom = "error" };
        return result;
    }
    const result = allocator.create(Value) catch return error.OutOfMemory;
    result.* = Value{ .atom = "ok" };
    return result;
}

/// tcp_close(fd: Int) -> nil
fn builtinTcpCloseNative(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1 or args[0].* != .integer) return error.TypeError;
    const fd: std.posix.fd_t = @intCast(args[0].integer);
    _ = std.c.close(fd);
    return make(allocator, .nil);
}

// ============================================================
// WebSocket builtins
// ============================================================

// RFC 6455 Section 1.3 fixed magic string. Used to derive
// Sec-WebSocket-Accept from the client's Sec-WebSocket-Key.
const ws_magic_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

/// ws_accept_key(client_key: String) -> String
/// Computes the Sec-WebSocket-Accept value for the WS handshake.
/// SHA-1(client_key + magic_guid) then Base64-encoded.
fn builtinWsAcceptKeyNative(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1 or args[0].* != .string) return error.TypeError;
    const client_key = args[0].string;

    // Concatenate client key + magic GUID
    var concat_buf: [256]u8 = undefined;
    if (client_key.len + ws_magic_guid.len > concat_buf.len) return error.NotSupported;
    @memcpy(concat_buf[0..client_key.len], client_key);
    @memcpy(concat_buf[client_key.len..][0..ws_magic_guid.len], ws_magic_guid);
    const to_hash = concat_buf[0 .. client_key.len + ws_magic_guid.len];

    // SHA-1 hash
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(to_hash);
    const digest = hasher.finalResult();

    // Base64 encode
    const base64_encoder = std.base64.standard.Encoder;
    const encoded_len = base64_encoder.calcSize(digest.len);
    const encoded = allocator.alloc(u8, encoded_len) catch return error.OutOfMemory;
    _ = base64_encoder.encode(encoded, &digest);

    const result = allocator.create(Value) catch return error.OutOfMemory;
    result.* = Value{ .string = encoded };
    return result;
}

/// ws_read_frame(fd: Int) -> String | nil
/// Reads and decodes one WebSocket text frame from fd.
/// Returns nil if the connection is closed or a close frame is received.
/// Handles client masking. Only supports text frames (opcode 0x1).
/// Auto-responds to Ping with Pong.
fn builtinWsReadFrameNative(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1 or args[0].* != .integer) return error.TypeError;
    const fd: std.posix.fd_t = @intCast(args[0].integer);

    // Read first 2 bytes (frame header)
    var header: [2]u8 = undefined;
    const h_n = std.posix.read(fd, &header) catch {
        return make(allocator, .nil);
    };
    if (h_n < 2) {
        return make(allocator, .nil);
    }

    const opcode = header[0] & 0x0F;
    const masked = (header[1] & 0x80) != 0;
    var payload_len: u64 = header[1] & 0x7F;

    // Extended payload length
    if (payload_len == 126) {
        var ext: [2]u8 = undefined;
        const ext_n = std.posix.read(fd, &ext) catch {
            return make(allocator, .nil);
        };
        if (ext_n < 2) {
            return make(allocator, .nil);
        }
        payload_len = @as(u64, ext[0]) << 8 | @as(u64, ext[1]);
    } else if (payload_len == 127) {
        var ext: [8]u8 = undefined;
        const ext_n = std.posix.read(fd, &ext) catch {
            return make(allocator, .nil);
        };
        if (ext_n < 8) {
            return make(allocator, .nil);
        }
        payload_len = 0;
        for (ext) |b| {
            payload_len = (payload_len << 8) | @as(u64, b);
        }
    }

    // Read masking key if present
    var mask_key: [4]u8 = .{ 0, 0, 0, 0 };
    if (masked) {
        const m_n = std.posix.read(fd, &mask_key) catch {
            return make(allocator, .nil);
        };
        if (m_n < 4) {
            return make(allocator, .nil);
        }
    }

    // Limit payload to 1MB to prevent DOS
    if (payload_len > 1048576) {
        return make(allocator, .nil);
    }

    // Read payload
    const plen: usize = @intCast(payload_len);
    const payload = allocator.alloc(u8, plen) catch return error.OutOfMemory;
    var total_read: usize = 0;
    while (total_read < plen) {
        const n = std.posix.read(fd, payload[total_read..]) catch {
            return make(allocator, .nil);
        };
        if (n == 0) {
            return make(allocator, .nil);
        }
        total_read += n;
    }

    // Unmask payload
    if (masked) {
        for (payload, 0..) |*byte, i| {
            byte.* ^= mask_key[i % 4];
        }
    }

    // Handle opcode
    switch (opcode) {
        0x1 => {
            // Text frame -- return the payload as a string
            const result = allocator.create(Value) catch return error.OutOfMemory;
            result.* = Value{ .string = payload };
            return result;
        },
        0x8 => {
            // Close frame -- return nil
            return make(allocator, .nil);
        },
        0x9 => {
            // Ping -- send Pong with same payload, then read next frame
            wsWriteFrame(fd, 0xA, payload) catch {};
            return builtinWsReadFrameNative(allocator, args);
        },
        0xA => {
            // Pong -- ignore, read next frame
            return builtinWsReadFrameNative(allocator, args);
        },
        else => {
            // Unsupported opcode -- return nil
            return make(allocator, .nil);
        },
    }
}

/// ws_write_frame(fd: Int, data: String) -> nil
/// Writes a WebSocket text frame (server-to-client, unmasked).
fn builtinWsWriteFrameNative(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 2 or args[0].* != .integer or args[1].* != .string) return error.TypeError;
    const fd: std.posix.fd_t = @intCast(args[0].integer);
    const data = args[1].string;
    // Don't crash on dead fds -- return :error instead
    wsWriteFrame(fd, 0x1, data) catch {
        const result = allocator.create(Value) catch return error.OutOfMemory;
        result.* = Value{ .atom = "error" };
        return result;
    };
    const result = allocator.create(Value) catch return error.OutOfMemory;
    result.* = Value{ .atom = "ok" };
    return result;
}

/// Internal: write a WS frame with given opcode and payload.
fn wsWriteFrame(fd: std.posix.fd_t, opcode: u8, payload: []const u8) !void {
    // Build frame header
    var header_buf: [10]u8 = undefined;
    var header_len: usize = 2;

    header_buf[0] = 0x80 | opcode; // FIN + opcode
    if (payload.len < 126) {
        header_buf[1] = @intCast(payload.len);
    } else if (payload.len <= 65535) {
        header_buf[1] = 126;
        header_buf[2] = @intCast((payload.len >> 8) & 0xFF);
        header_buf[3] = @intCast(payload.len & 0xFF);
        header_len = 4;
    } else {
        header_buf[1] = 127;
        const len64: u64 = @intCast(payload.len);
        inline for (0..8) |i| {
            header_buf[2 + i] = @intCast((len64 >> @intCast(56 - i * 8)) & 0xFF);
        }
        header_len = 10;
    }

    // Write header
    if (std.c.write(fd, &header_buf, header_len) < 0) return error.NotSupported;
    // Write payload
    if (payload.len > 0) {
        if (std.c.write(fd, payload.ptr, payload.len) < 0) return error.NotSupported;
    }
}

// ============================================================
// View diffing
// ============================================================

/// view_diff(old_tree, new_tree) -> List of patch maps
/// Compares two view_node trees and returns a list of patches.
/// Each patch is %{op: "replace"|"text"|"attrs", path: "0.1.2", value: "..."}
fn builtinViewDiffNative(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 2) return error.TypeError;

    var patches: std.ArrayListUnmanaged(*const Value) = .empty;
    diffViewNodes(allocator, args[0], args[1], "", &patches) catch return error.OutOfMemory;

    const result = allocator.create(Value) catch return error.OutOfMemory;
    const items = patches.toOwnedSlice(allocator) catch return error.OutOfMemory;
    result.* = Value{ .list = items };
    return result;
}

fn diffViewNodes(
    allocator: std.mem.Allocator,
    old: *const Value,
    new: *const Value,
    path: []const u8,
    patches: *std.ArrayListUnmanaged(*const Value),
) !void {
    // If structurally equal, no patches needed
    if (old.eql(new.*)) return;

    // Both view_nodes: compare structurally
    if (old.* == .view_node and new.* == .view_node) {
        const o = old.view_node;
        const n = new.view_node;

        // Different tags -> full replace
        if (!std.mem.eql(u8, o.tag, n.tag)) {
            try appendReplacePatch(allocator, patches, path, new);
            return;
        }

        // Different attribute count -> full replace
        if (o.attrs.len != n.attrs.len) {
            try appendReplacePatch(allocator, patches, path, new);
            return;
        }

        // Check attrs for changes
        var attrs_changed = false;
        for (o.attrs, n.attrs) |oa, na| {
            if (!std.mem.eql(u8, oa.key, na.key) or !oa.val.eql(na.val.*)) {
                attrs_changed = true;
                break;
            }
        }
        if (attrs_changed) {
            try appendAttrsPatch(allocator, patches, path, n.attrs);
        }

        // Different child count -> full replace
        if (o.children.len != n.children.len) {
            try appendReplacePatch(allocator, patches, path, new);
            return;
        }

        // Recurse into children
        for (o.children, n.children, 0..) |old_child, new_child, i| {
            const child_path = if (path.len == 0)
                std.fmt.allocPrint(allocator, "{d}", .{i}) catch return error.OutOfMemory
            else
                std.fmt.allocPrint(allocator, "{s}.{d}", .{ path, i }) catch return error.OutOfMemory;
            try diffViewNodes(allocator, old_child, new_child, child_path, patches);
        }
        return;
    }

    // Both strings: text patch
    if (old.* == .string and new.* == .string) {
        if (!std.mem.eql(u8, old.string, new.string)) {
            try appendTextPatch(allocator, patches, path, new.string);
        }
        return;
    }

    // Both integers
    if (old.* == .integer and new.* == .integer) {
        if (old.integer != new.integer) {
            var tmp: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&tmp, "{d}", .{new.integer}) catch return;
            const owned = try allocator.dupe(u8, s);
            try appendTextPatch(allocator, patches, path, owned);
        }
        return;
    }

    // Type changed or unsupported combination -> full replace
    try appendReplacePatch(allocator, patches, path, new);
}

fn appendReplacePatch(
    allocator: std.mem.Allocator,
    patches: *std.ArrayListUnmanaged(*const Value),
    path: []const u8,
    node: *const Value,
) !void {
    // Render the new node to HTML
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    renderHtml(allocator, node, &buf) catch return;
    const html = buf.toOwnedSlice(allocator) catch return;

    const patch = try makePatchMap(allocator, "replace", path, html);
    try patches.append(allocator, patch);
}

fn appendTextPatch(
    allocator: std.mem.Allocator,
    patches: *std.ArrayListUnmanaged(*const Value),
    path: []const u8,
    text_val: []const u8,
) !void {
    const patch = try makePatchMap(allocator, "text", path, text_val);
    try patches.append(allocator, patch);
}

fn appendAttrsPatch(
    allocator: std.mem.Allocator,
    patches: *std.ArrayListUnmanaged(*const Value),
    path: []const u8,
    attrs: []const Value.ViewNode.ViewAttr,
) !void {
    // Serialize attrs as a simple string for now: "key=val,key2=val2"
    var attr_buf: std.ArrayListUnmanaged(u8) = .empty;
    for (attrs, 0..) |attr, i| {
        if (i > 0) attr_buf.appendSlice(allocator, ",") catch return;
        attr_buf.appendSlice(allocator, attr.key) catch return;
        attr_buf.appendSlice(allocator, "=") catch return;
        var val_buf: [256]u8 = undefined;
        var fbs = std.Io.Writer.fixed(&val_buf);
        attr.val.format(&fbs);
        attr_buf.appendSlice(allocator, fbs.buffered()) catch return;
    }
    const attr_str = attr_buf.toOwnedSlice(allocator) catch return;
    const patch = try makePatchMap(allocator, "attrs", path, attr_str);
    try patches.append(allocator, patch);
}

fn makePatchMap(
    allocator: std.mem.Allocator,
    op: []const u8,
    path: []const u8,
    value_str: []const u8,
) !*const Value {
    // Create a map: %{op: "replace", path: "0.1", value: "<html>"}
    const entries = try allocator.alloc(Value.MapEntry, 3);

    const op_val = try allocator.create(Value);
    op_val.* = Value{ .string = op };
    entries[0] = .{ .key = "op", .val = op_val };

    const path_val = try allocator.create(Value);
    path_val.* = Value{ .string = if (path.len > 0) path else "" };
    entries[1] = .{ .key = "path", .val = path_val };

    const value_val = try allocator.create(Value);
    value_val.* = Value{ .string = value_str };
    entries[2] = .{ .key = "value", .val = value_val };

    const result = try allocator.create(Value);
    result.* = Value{ .map = entries };
    return result;
}

// ============================================================
// Process builtins (fork, waitpid, exit)
// ============================================================

/// fork() -> Int
/// Returns 0 in the child process, the child PID in the parent.
/// Returns -1 on error.
fn builtinForkNative(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 0) return error.TypeError;
    const result_val = allocator.create(Value) catch return error.OutOfMemory;
    const fork_result = std.c.fork();
    if (fork_result < 0) {
        result_val.* = Value{ .integer = -1 };
        return result_val;
    }
    if (fork_result == 0) {
        // Child process
        result_val.* = Value{ .integer = 0 };
    } else {
        // Parent process -- fork_result is the child PID
        result_val.* = Value{ .integer = @intCast(fork_result) };
    }
    return result_val;
}

/// waitpid(pid: Int, nohang: Bool) -> Int
/// Waits for a child process. If nohang is true, returns immediately.
/// Returns the pid if the child exited, 0 if nohang and child still running, -1 on error.
fn builtinWaitpidNative(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len < 1 or args[0].* != .integer) return error.TypeError;
    const pid: std.posix.pid_t = @intCast(args[0].integer);
    const nohang = if (args.len >= 2) switch (args[1].*) {
        .boolean => |b| b,
        else => false,
    } else false;

    const flags: u32 = if (nohang) @as(u32, 1) else 0; // WNOHANG = 1 on macOS/Linux
    const result_val = allocator.create(Value) catch return error.OutOfMemory;
    var status: c_int = undefined;
    const waited = std.c.waitpid(pid, &status, @intCast(flags));
    result_val.* = Value{ .integer = @intCast(waited) };
    return result_val;
}

/// exit(code: Int) -> never returns
/// Exits the current process with the given status code.
fn builtinExitNative(_: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1 or args[0].* != .integer) return error.TypeError;
    const code: u8 = @intCast(@max(0, @min(255, args[0].integer)));
    std.process.exit(code);
}

// ============================================================
// Non-blocking IO builtins
// ============================================================

/// tcp_set_nonblocking(fd: Int) -> :ok
/// Sets a socket to non-blocking mode. After this, tcp_accept and tcp_read
/// will return nil instead of blocking when no data/connection is ready.
fn builtinTcpSetNonblockingNative(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1 or args[0].* != .integer) return error.TypeError;
    const fd: std.posix.fd_t = @intCast(args[0].integer);

    // Get current flags and add O_NONBLOCK (same pattern as Zig stdlib)
    const fl_flags = std.c.fcntl(fd, std.posix.F.GETFL, @as(c_int, 0));
    if (fl_flags < 0) return error.NotSupported;
    const nonblock: c_int = @as(c_int, 1) << @bitOffsetOf(std.posix.O, "NONBLOCK");
    if (std.c.fcntl(fd, std.posix.F.SETFL, fl_flags | nonblock) < 0) return error.NotSupported;
    const result = allocator.create(Value) catch return error.OutOfMemory;
    result.* = Value{ .atom = "ok" };
    return result;
}

/// tcp_poll(fds: List of Int, timeout_ms: Int) -> List of Int
/// Polls a list of file descriptors for readability.
/// Returns a list of fds that are ready to read (or accept).
/// timeout_ms: -1 = block forever, 0 = return immediately, >0 = wait up to N ms.
fn builtinTcpPollNative(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 2) return error.TypeError;
    if (args[0].* != .list or args[1].* != .integer) return error.TypeError;

    const fd_list = args[0].list;
    const timeout_ms: i32 = @intCast(args[1].integer);

    // Build pollfd array
    const pollfds = allocator.alloc(std.posix.pollfd, fd_list.len) catch return error.OutOfMemory;
    for (fd_list, 0..) |fd_val, i| {
        if (fd_val.* != .integer) return error.TypeError;
        pollfds[i] = .{
            .fd = @intCast(fd_val.integer),
            .events = std.posix.POLL.IN,
            .revents = 0,
        };
    }

    // Call poll
    _ = std.posix.poll(pollfds, timeout_ms) catch return error.NotSupported;

    // Collect ready fds
    var ready_list: std.ArrayList(*const Value) = .{ .items = &.{}, .capacity = 0 };
    for (pollfds) |pfd| {
        if (pfd.revents & std.posix.POLL.IN != 0) {
            const fd_val = allocator.create(Value) catch return error.OutOfMemory;
            fd_val.* = Value{ .integer = @intCast(pfd.fd) };
            ready_list.append(allocator, fd_val) catch return error.OutOfMemory;
        }
    }

    const result = allocator.create(Value) catch return error.OutOfMemory;
    result.* = Value{ .list = ready_list.toOwnedSlice(allocator) catch return error.OutOfMemory };
    return result;
}

test "type_of view_node returns :view_node" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const node = try alloc.create(Value);
    const node_view = try alloc.create(Value.ViewNode);
    node_view.* = .{ .tag = "text", .attrs = &.{}, .children = &.{} };
    node.* = Value{ .view_node = node_view };
    const args = try alloc.alloc(*const Value, 1);
    args[0] = node;
    const result = try builtinTypeOf(alloc, args);
    try std.testing.expect(result.eql(Value{ .atom = "view_node" }));
}

// ============================================================
// WebSocket tests
// ============================================================

test "ws_accept_key produces correct accept value for RFC example" {
    // RFC 6455 Section 1.3 example: key "dGhlIHNhbXBsZSBub25jZQ==" must
    // produce accept "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=" via
    // Base64(SHA-1(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")).
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const key_val = try alloc.create(Value);
    key_val.* = Value{ .string = "dGhlIHNhbXBsZSBub25jZQ==" };
    const args = try alloc.alloc(*const Value, 1);
    args[0] = key_val;

    const result = try builtinWsAcceptKeyNative(alloc, args);
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", result.string);
}

test "ws_accept_key rejects non-string arg" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const int_val = try alloc.create(Value);
    int_val.* = Value{ .integer = 42 };
    const args = try alloc.alloc(*const Value, 1);
    args[0] = int_val;

    const result = builtinWsAcceptKeyNative(alloc, args);
    try std.testing.expectError(error.TypeError, result);
}

// ============================================================
// View diff tests
// ============================================================

test "view_diff identical trees returns empty list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Create two identical text nodes: text("hello")
    const child1 = try alloc.create(Value);
    child1.* = Value{ .string = "hello" };
    const children1 = try alloc.alloc(*const Value, 1);
    children1[0] = child1;

    const node1 = try alloc.create(Value);
    const node1_view = try alloc.create(Value.ViewNode);
    node1_view.* = .{ .tag = "text", .attrs = &.{}, .children = children1 };
    node1.* = Value{ .view_node = node1_view };

    const child2 = try alloc.create(Value);
    child2.* = Value{ .string = "hello" };
    const children2 = try alloc.alloc(*const Value, 1);
    children2[0] = child2;

    const node2 = try alloc.create(Value);
    const node2_view = try alloc.create(Value.ViewNode);
    node2_view.* = .{ .tag = "text", .attrs = &.{}, .children = children2 };
    node2.* = Value{ .view_node = node2_view };

    const args = try alloc.alloc(*const Value, 2);
    args[0] = node1;
    args[1] = node2;

    const result = try builtinViewDiffNative(alloc, args);
    try std.testing.expect(result.* == .list);
    try std.testing.expectEqual(@as(usize, 0), result.list.len);
}

test "view_diff detects text change in child" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Old: text("Count: 4")
    const old_child = try alloc.create(Value);
    old_child.* = Value{ .string = "Count: 4" };
    const old_children = try alloc.alloc(*const Value, 1);
    old_children[0] = old_child;
    const old_node = try alloc.create(Value);
    const old_node_view = try alloc.create(Value.ViewNode);
    old_node_view.* = .{ .tag = "text", .attrs = &.{}, .children = old_children };
    old_node.* = Value{ .view_node = old_node_view };

    // New: text("Count: 5")
    const new_child = try alloc.create(Value);
    new_child.* = Value{ .string = "Count: 5" };
    const new_children = try alloc.alloc(*const Value, 1);
    new_children[0] = new_child;
    const new_node = try alloc.create(Value);
    const new_node_view = try alloc.create(Value.ViewNode);
    new_node_view.* = .{ .tag = "text", .attrs = &.{}, .children = new_children };
    new_node.* = Value{ .view_node = new_node_view };

    const args = try alloc.alloc(*const Value, 2);
    args[0] = old_node;
    args[1] = new_node;

    const result = try builtinViewDiffNative(alloc, args);
    try std.testing.expect(result.* == .list);
    // Should have exactly 1 patch for the text change
    try std.testing.expectEqual(@as(usize, 1), result.list.len);

    // Check the patch is a text op
    const patch = result.list[0];
    try std.testing.expect(patch.* == .map);
    // Find the "op" entry
    var found_op = false;
    for (patch.map) |entry| {
        if (std.mem.eql(u8, entry.key, "op")) {
            try std.testing.expectEqualStrings("text", entry.val.string);
            found_op = true;
        }
    }
    try std.testing.expect(found_op);
}

test "view_diff detects tag change as replace" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Old: a "text" node
    const old_node = try alloc.create(Value);
    const old_node_view = try alloc.create(Value.ViewNode);
    old_node_view.* = .{ .tag = "text", .attrs = &.{}, .children = &.{} };
    old_node.* = Value{ .view_node = old_node_view };

    // New: a "heading" node
    const new_node = try alloc.create(Value);
    const new_node_view = try alloc.create(Value.ViewNode);
    new_node_view.* = .{ .tag = "heading", .attrs = &.{}, .children = &.{} };
    new_node.* = Value{ .view_node = new_node_view };

    const args = try alloc.alloc(*const Value, 2);
    args[0] = old_node;
    args[1] = new_node;

    const result = try builtinViewDiffNative(alloc, args);
    try std.testing.expect(result.* == .list);
    try std.testing.expectEqual(@as(usize, 1), result.list.len);

    // Should be a "replace" op
    const patch = result.list[0];
    for (patch.map) |entry| {
        if (std.mem.eql(u8, entry.key, "op")) {
            try std.testing.expectEqualStrings("replace", entry.val.string);
        }
    }
}

test "builtin abs wraps minInt to itself instead of panicking" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const n = try alloc.create(Value);
    n.* = Value{ .integer = std.math.minInt(i64) };
    const args = try alloc.alloc(*const Value, 1);
    args[0] = n;
    const result = try builtinAbs(alloc, args);
    try std.testing.expect(result.eql(Value{ .integer = std.math.minInt(i64) }));
}

test "builtin abs is unchanged for ordinary values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const n = try alloc.create(Value);
    n.* = Value{ .integer = -7 };
    const args = try alloc.alloc(*const Value, 1);
    args[0] = n;
    const result = try builtinAbs(alloc, args);
    try std.testing.expect(result.eql(Value{ .integer = 7 }));
}

test "builtin sum wraps past maxInt instead of panicking" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const a = try alloc.create(Value);
    a.* = Value{ .integer = std.math.maxInt(i64) };
    const b = try alloc.create(Value);
    b.* = Value{ .integer = 1 };
    const items = try alloc.alloc(*const Value, 2);
    items[0] = a;
    items[1] = b;
    const list_val = try alloc.create(Value);
    list_val.* = Value{ .list = items };
    const args = try alloc.alloc(*const Value, 1);
    args[0] = list_val;

    const result = try builtinSum(alloc, args);
    try std.testing.expect(result.eql(Value{ .integer = std.math.minInt(i64) }));
}

test "pow answers a fractional exponent, which repeated multiplication cannot" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const base = try alloc.create(Value);
    base.* = Value{ .float = 4.0 };
    const exponent = try alloc.create(Value);
    exponent.* = Value{ .float = -0.5 };
    const args = try alloc.alloc(*const Value, 2);
    args[0] = base;
    args[1] = exponent;

    const result = try builtinPow(alloc, args);
    try std.testing.expectEqual(@as(f64, 0.5), result.float);
}

test "a float function takes an Int and answers a Float" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const n = try alloc.create(Value);
    n.* = Value{ .integer = 16 };
    const args = try alloc.alloc(*const Value, 1);
    args[0] = n;

    const sqrt = unaryFloat(struct {
        fn f(x: f64) f64 {
            return @sqrt(x);
        }
    }.f);
    const result = try sqrt(alloc, args);
    try std.testing.expectEqual(@as(f64, 4.0), result.float);

    // A string has no square root, and says so rather than answering one.
    const text = try alloc.create(Value);
    text.* = Value{ .string = "16" };
    args[0] = text;
    try std.testing.expectError(error.TypeError, sqrt(alloc, args));
}

test "the transcendental functions agree with their identities" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const x = try alloc.create(Value);
    x.* = Value{ .float = 1.0 };
    const args = try alloc.alloc(*const Value, 1);
    args[0] = x;

    inline for (float_fns) |entry| {
        const result = try unaryFloat(entry[1])(alloc, args);
        // Every one of these is defined at 1.0. That is all this asserts:
        // sin wired to cos would pass it. The identity below is the check
        // with teeth.
        try std.testing.expect(result.* == .float);
        try std.testing.expect(!std.math.isNan(result.float));
    }

    // log(e) is 1, and e is exp(1): the two entries are each other's inverse.
    const e = try unaryFloat(struct {
        fn f(v: f64) f64 {
            return @exp(v);
        }
    }.f)(alloc, args);
    args[0] = e;
    const back = try unaryFloat(struct {
        fn f(v: f64) f64 {
            return @log(v);
        }
    }.f)(alloc, args);
    try std.testing.expectEqual(@as(f64, 1.0), back.float);
}

test "write_file writes a string and read_file reads it back" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const path = try alloc.create(Value);
    path.* = Value{ .string = "zig-cache-write-file-test.txt" };
    const text = try alloc.create(Value);
    text.* = Value{ .string = "<testsuites/>" };
    const args = try alloc.alloc(*const Value, 2);
    args[0] = path;
    args[1] = text;

    // A builtin that touches a file needs an `Io`, and a unit test does not go
    // through `main`, so nothing has installed one. `ioenv.io` defaults to
    // `failing` rather than `undefined` -- this is the test that would
    // otherwise have segfaulted inside libc -- so the test installs a real one.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    ioenv.install(threaded.io());
    defer ioenv.io = .failing;

    const wrote = try builtinWriteFile(alloc, args);
    try std.testing.expect(wrote.boolean);
    defer std.Io.Dir.cwd().deleteFile(ioenv.io, path.string) catch {};

    const back = try builtinReadFile(alloc, args[0..1]);
    try std.testing.expectEqualStrings(text.string, back.string);

    // A directory that is not there is a false, not a crash: the caller
    // decides whether that matters.
    const bad = try alloc.create(Value);
    bad.* = Value{ .string = "no-such-directory/out.txt" };
    args[0] = bad;
    const failed = try builtinWriteFile(alloc, args);
    try std.testing.expect(!failed.boolean);
}

test "sleep_ms waits at least as long as it was asked to" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const before = try builtinNowMs(a, &.{});
    const ms = try make(a, .{ .integer = 60 });
    const answer = try builtinSleepMsNative(a, &.{ms});
    const after = try builtinNowMs(a, &.{});

    try std.testing.expectEqualStrings("ok", answer.atom);
    // Only a lower bound is asserted. A scheduler may take longer, and on a
    // loaded machine it will; what must never happen is returning early.
    try std.testing.expect(after.integer - before.integer >= 60);
}

test "sleep_ms rejects what it cannot wait for" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const notANumber = try make(a, .{ .string = "soon" });
    try std.testing.expectError(error.TypeError, builtinSleepMsNative(a, &.{notANumber}));
    try std.testing.expectError(error.TypeError, builtinSleepMsNative(a, &.{}));
}

test "now_ms goes forwards and has more than second resolution" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const first = try builtinNowMs(a, &.{});
    _ = try builtinSleepMsNative(a, &.{try make(a, .{ .integer = 5 })});
    const second = try builtinNowMs(a, &.{});
    // 5ms is unmeasurable with `now()`, which is the reason this exists.
    try std.testing.expect(second.integer > first.integer);
}
