//! The character-aware string builtins. `length`, `slice`, `index_of`,
//! `upcase` and `downcase` count and cut bytes, and keep doing so; these are
//! the ones that know what a character is.
//!
//!   utf8_valid(s)                -> Bool
//!   utf8_scrub(s)                -> String   ill-formed bytes -> U+FFFD
//!   utf8_length(s)               -> Int      code points
//!   utf8_slice(s, start, count)  -> String   by code point
//!   utf8_upcase(s), utf8_downcase(s) -> String
//!   graphemes(s)                 -> List of String
//!   grapheme_length(s)           -> Int      extended grapheme clusters
//!   grapheme_slice(s, start, count) -> String by cluster
//!   grapheme_take(s, n)          -> String   the first n clusters
//!
//! Every one but utf8_valid and utf8_scrub raises TypeError when s is not
//! UTF-8, and says on stderr at which byte. There is no answer to "how many
//! characters" in bytes that are not text, and a guess (Elixir counts each
//! stray byte as a character) would put mojibake on the page with no trace
//! of where it came from. Text from outside is checked or repaired where it
//! comes in, with utf8_valid or utf8_scrub.
//!
//! A negative start, count or n also raises. `slice` clamps a negative to 0
//! and Elixir's String.slice counts one back from the end; picking either
//! here would be right for half the callers and silently wrong for the rest.

const std = @import("std");
const builtin = @import("builtin");
const ioenv = @import("ioenv.zig");
const unicode = @import("unicode.zig");
const Value = @import("value.zig").Value;
const EvalError = @import("builtins.zig").EvalError;

const is_wasm = builtin.target.cpu.arch == .wasm32;

fn complain(comptime fmt: []const u8, args: anytype) void {
    if (is_wasm or builtin.is_test) return;
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    std.Io.File.stderr().writeStreamingAll(ioenv.io, msg) catch {};
}

fn box(allocator: std.mem.Allocator, v: Value) EvalError!*const Value {
    const p = allocator.create(Value) catch return error.OutOfMemory;
    p.* = v;
    return p;
}

/// The string argument, which must be valid UTF-8.
fn textArg(comptime name: []const u8, v: *const Value) EvalError![]const u8 {
    if (v.* != .string) return error.TypeError;
    const s = v.string;
    if (unicode.firstInvalid(s)) |at| {
        complain(name ++ ": not UTF-8: byte {d} of {d} is 0x{X:0>2}; check with utf8_valid or repair with utf8_scrub first\n", .{ at, s.len, s[at] });
        return error.TypeError;
    }
    return s;
}

fn countArg(comptime name: []const u8, what: []const u8, v: *const Value) EvalError!usize {
    if (v.* != .integer) return error.TypeError;
    if (v.integer < 0) {
        complain(name ++ ": {s} is {d}; it must be 0 or more\n", .{ what, v.integer });
        return error.TypeError;
    }
    return @intCast(v.integer);
}

pub fn utf8Valid(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1 or args[0].* != .string) return error.TypeError;
    return box(allocator, .{ .boolean = unicode.firstInvalid(args[0].string) == null });
}

pub fn utf8Scrub(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1 or args[0].* != .string) return error.TypeError;
    const out = unicode.scrub(allocator, args[0].string) catch return error.OutOfMemory;
    if (out.ptr == args[0].string.ptr) return args[0];
    return box(allocator, .{ .string = out });
}

pub fn utf8Length(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1) return error.TypeError;
    const s = try textArg("utf8_length", args[0]);
    return box(allocator, .{ .integer = @intCast(unicode.codepointCount(s)) });
}

pub fn utf8Slice(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 3) return error.TypeError;
    const s = try textArg("utf8_slice", args[0]);
    const start = try countArg("utf8_slice", "start", args[1]);
    const count = try countArg("utf8_slice", "count", args[2]);
    return box(allocator, .{ .string = unicode.codepointSlice(s, start, count) });
}

fn caseChange(comptime name: []const u8, which: unicode.Case, allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1) return error.TypeError;
    const s = try textArg(name, args[0]);
    const out = unicode.changeCase(allocator, s, which) catch return error.OutOfMemory;
    return box(allocator, .{ .string = out });
}

pub fn utf8Upcase(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    return caseChange("utf8_upcase", .upper, allocator, args);
}

pub fn utf8Downcase(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    return caseChange("utf8_downcase", .lower, allocator, args);
}

pub fn graphemes(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1) return error.TypeError;
    const s = try textArg("graphemes", args[0]);
    var parts: std.ArrayList(*const Value) = .empty;
    var it = unicode.GraphemeIterator.init(s);
    while (it.next()) |g| {
        parts.append(allocator, try box(allocator, .{ .string = g })) catch return error.OutOfMemory;
    }
    return box(allocator, .{ .list = parts.items });
}

pub fn graphemeLength(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 1) return error.TypeError;
    const s = try textArg("grapheme_length", args[0]);
    return box(allocator, .{ .integer = @intCast(unicode.graphemeCount(s)) });
}

pub fn graphemeSlice(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 3) return error.TypeError;
    const s = try textArg("grapheme_slice", args[0]);
    const start = try countArg("grapheme_slice", "start", args[1]);
    const count = try countArg("grapheme_slice", "count", args[2]);
    return box(allocator, .{ .string = unicode.graphemeSlice(s, start, count) });
}

pub fn graphemeTake(allocator: std.mem.Allocator, args: []const *const Value) EvalError!*const Value {
    if (args.len != 2) return error.TypeError;
    const s = try textArg("grapheme_take", args[0]);
    const n = try countArg("grapheme_take", "n", args[1]);
    return box(allocator, .{ .string = unicode.graphemeSlice(s, 0, n) });
}

// ---------------------------------------------------------------------------

const testing = std.testing;

fn call(f: anytype, a: std.mem.Allocator, vals: []const Value) EvalError!*const Value {
    const args = a.alloc(*const Value, vals.len) catch return error.OutOfMemory;
    for (vals, 0..) |v, i| args[i] = try box(a, v);
    return f(a, args);
}

test "the builtins: counts, slices, case, list of clusters" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const heart = Value{ .string = "❤️" };
    try testing.expect((try call(utf8Length, a, &.{heart})).eql(.{ .integer = 2 }));
    try testing.expect((try call(graphemeLength, a, &.{heart})).eql(.{ .integer = 1 }));
    try testing.expect((try call(utf8Valid, a, &.{heart})).eql(.{ .boolean = true }));
    try testing.expect((try call(utf8Valid, a, &.{.{ .string = "\xe2\x9d" }})).eql(.{ .boolean = false }));
    try testing.expectEqualStrings("\u{FFFD}", (try call(utf8Scrub, a, &.{.{ .string = "\xe2\x9d" }})).string);
    try testing.expectEqualStrings("éll", (try call(utf8Slice, a, &.{ .{ .string = "héllo" }, .{ .integer = 1 }, .{ .integer = 3 } })).string);
    try testing.expectEqualStrings("🇺🇸b", (try call(graphemeSlice, a, &.{ .{ .string = "a🇺🇸b" }, .{ .integer = 1 }, .{ .integer = 5 } })).string);
    try testing.expectEqualStrings("a🇺🇸", (try call(graphemeTake, a, &.{ .{ .string = "a🇺🇸b" }, .{ .integer = 2 } })).string);
    try testing.expectEqualStrings("STRASSE", (try call(utf8Upcase, a, &.{.{ .string = "straße" }})).string);
    try testing.expectEqualStrings("ǆ", (try call(utf8Downcase, a, &.{.{ .string = "ǅ" }})).string);
    const gs = try call(graphemes, a, &.{.{ .string = "e\u{301}👨‍👩‍👧" }});
    try testing.expectEqual(@as(usize, 2), gs.list.len);
    try testing.expectEqualStrings("e\u{301}", gs.list[0].string);
    try testing.expectEqualStrings("👨‍👩‍👧", gs.list[1].string);
}

test "invalid UTF-8, a negative count and a non-string all raise TypeError" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bad = Value{ .string = "ok\xff" };
    try testing.expectError(error.TypeError, call(utf8Length, a, &.{bad}));
    try testing.expectError(error.TypeError, call(graphemeLength, a, &.{bad}));
    try testing.expectError(error.TypeError, call(graphemes, a, &.{bad}));
    try testing.expectError(error.TypeError, call(utf8Upcase, a, &.{bad}));
    try testing.expectError(error.TypeError, call(utf8Downcase, a, &.{bad}));
    try testing.expectError(error.TypeError, call(utf8Slice, a, &.{ bad, .{ .integer = 0 }, .{ .integer = 1 } }));
    try testing.expectError(error.TypeError, call(graphemeTake, a, &.{ bad, .{ .integer = 1 } }));
    try testing.expectError(error.TypeError, call(utf8Slice, a, &.{ .{ .string = "abc" }, .{ .integer = -1 }, .{ .integer = 1 } }));
    try testing.expectError(error.TypeError, call(graphemeSlice, a, &.{ .{ .string = "abc" }, .{ .integer = 0 }, .{ .integer = -1 } }));
    try testing.expectError(error.TypeError, call(graphemeTake, a, &.{ .{ .string = "abc" }, .{ .integer = -2 } }));
    try testing.expectError(error.TypeError, call(utf8Length, a, &.{.{ .integer = 3 }}));
    try testing.expectError(error.TypeError, call(utf8Valid, a, &.{.nil}));
    // The byte builtins are untouched: length("❤️") is still 6.
    // (Asserted in lib/builtin_test.blimp, where `length` is reachable.)
}
