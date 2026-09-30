//! The JSON blimp.wasm hands the page, and a writer that notices when a
//! write fails.
//!
//! Two ways this went wrong without a word. A view text holding a control
//! character (`\r`, `\e`, anything under 0x20 but `\n` and `\t`) went into
//! the view JSON raw, which JSON forbids, so the page's parse failed and the
//! mount reported that no view was produced. And every write was `catch {}`:
//! once the buffers grow, a full buffer can no longer cut the output, but an
//! allocation that fails still would, and nothing would say so.
//!
//! Kept apart from wasm_api.zig, which only builds for wasm32, so that
//! `zig build test` exercises it.

const std = @import("std");
const Writer = std.Io.Writer;
const Value = @import("value.zig").Value;

/// Wraps a writer and remembers whether any write to it failed. Code that
/// writes with `catch {}` -- Value.format does, and so does most of the
/// state JSON -- writes through `guard.writer` and asks `guard.ok()` at the
/// end, so a failure deep inside it is not lost.
///
/// With `escape` set, the bytes are written as the inside of a JSON string:
/// that is how a value's formatted text becomes a view text node, without
/// formatting it to a temporary first.
pub const Guard = struct {
    inner: *Writer,
    escape: bool,
    failed: bool = false,
    buf: [256]u8 = undefined,
    writer: Writer,

    pub fn init(inner: *Writer, escape: bool) Guard {
        return .{
            .inner = inner,
            .escape = escape,
            .writer = .{ .vtable = &.{ .drain = drain }, .buffer = &.{} },
        };
    }

    /// Call once the Guard is at its final address (the writer's buffer
    /// points into it).
    pub fn start(self: *Guard) *Writer {
        self.writer.buffer = &self.buf;
        self.writer.end = 0;
        return &self.writer;
    }

    /// Flush what is buffered and say whether every write got through.
    pub fn finish(self: *Guard) Writer.Error!void {
        self.writer.flush() catch {
            self.failed = true;
        };
        if (self.failed) return error.WriteFailed;
    }

    fn emit(self: *Guard, bytes: []const u8) Writer.Error!void {
        if (self.escape) {
            try writeJsonStringBody(self.inner, bytes);
        } else {
            try self.inner.writeAll(bytes);
        }
    }

    fn drain(w: *Writer, data: []const []const u8, splat: usize) Writer.Error!usize {
        const self: *Guard = @alignCast(@fieldParentPtr("writer", w));
        errdefer self.failed = true;
        try self.emit(w.buffer[0..w.end]);
        w.end = 0;
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |d| {
            try self.emit(d);
            n += d.len;
        }
        const pattern = data[data.len - 1];
        for (0..splat) |_| {
            try self.emit(pattern);
            n += pattern.len;
        }
        return n;
    }
};

/// `s` as the inside of a JSON string: quote, backslash and every control
/// character escaped, everything else as it is.
pub fn writeJsonStringBody(w: *Writer, s: []const u8) Writer.Error!void {
    var from: usize = 0;
    for (s, 0..) |c, i| {
        const esc: ?[]const u8 = switch (c) {
            '"' => "\\\"",
            '\\' => "\\\\",
            '\n' => "\\n",
            '\r' => "\\r",
            '\t' => "\\t",
            0x08 => "\\b",
            0x0c => "\\f",
            else => null,
        };
        if (esc == null and c >= 0x20) continue;
        try w.writeAll(s[from..i]);
        if (esc) |e| try w.writeAll(e) else try w.print("\\u{x:0>4}", .{c});
        from = i + 1;
    }
    try w.writeAll(s[from..]);
}

pub fn writeJsonString(w: *Writer, s: []const u8) Writer.Error!void {
    try w.writeAll("\"");
    try writeJsonStringBody(w, s);
    try w.writeAll("\"");
}

/// `{"text":"..."}` holding `val` formatted the way the REPL shows it.
fn writeTextNode(w: *Writer, val: *const Value) Writer.Error!void {
    try w.writeAll("{\"text\":\"");
    var g = Guard.init(w, true);
    val.format(g.start());
    try g.finish();
    try w.writeAll("\"}");
}

/// A view_node tree as JSON for the JS renderer.
pub fn writeViewJson(w: *Writer, val: *const Value) Writer.Error!void {
    switch (val.*) {
        .view_node => |node| {
            try w.writeAll("{\"tag\":");
            try writeJsonString(w, node.tag);
            try w.writeAll(",\"attrs\":{");
            for (node.attrs, 0..) |attr, i| {
                if (i > 0) try w.writeAll(",");
                try writeJsonString(w, attr.key);
                try w.writeAll(":");
                try writeViewJson(w, attr.val);
            }
            try w.writeAll("},\"children\":[");
            for (node.children, 0..) |child, i| {
                if (i > 0) try w.writeAll(",");
                try writeViewJson(w, child);
            }
            try w.writeAll("]}");
        },
        .string => |s| {
            try w.writeAll("{\"text\":");
            try writeJsonString(w, s);
            try w.writeAll("}");
        },
        .atom => |a| try writeJsonString(w, a),
        .boolean => |b| try w.writeAll(if (b) "true" else "false"),
        // An attr that is nil is left off (el's contract; to_html does it).
        // It used to fall through to the text "nil", and an attribute that
        // is present at all -- data-full="nil" -- matches [data-full] in CSS.
        .nil => try w.writeAll("null"),
        // integers, floats, and anything else a view holds: its text
        else => try writeTextNode(w, val),
    }
}

pub const ReplyError = Writer.Error || error{Unrepresentable};

/// JSON for a reply: numbers, strings, true/false/null; atoms as strings;
/// lists and tuples as arrays; maps as objects; a view node as the object
/// writeViewJson makes. Anything else (a closure, an actor ref, a hole) is
/// error.Unrepresentable, so the host gets an error instead of a guess; a
/// write that fails is error.WriteFailed, which is not the same complaint.
pub fn writeReplyJson(w: *Writer, val: *const Value) ReplyError!void {
    switch (val.*) {
        .integer => |n| try w.print("{d}", .{n}),
        .float => |f| {
            if (std.math.isFinite(f)) {
                try w.print("{d}", .{f});
            } else {
                try w.writeAll("null");
            }
        },
        .boolean => |b| try w.writeAll(if (b) "true" else "false"),
        .nil => try w.writeAll("null"),
        .string => |s| try writeJsonString(w, s),
        .atom => |a| try writeJsonString(w, a),
        .list, .tuple => |items| {
            try w.writeAll("[");
            for (items, 0..) |item, i| {
                if (i > 0) try w.writeAll(",");
                try writeReplyJson(w, item);
            }
            try w.writeAll("]");
        },
        .map => |entries| {
            try w.writeAll("{");
            for (entries, 0..) |entry, i| {
                if (i > 0) try w.writeAll(",");
                try writeJsonString(w, entry.key);
                try w.writeAll(":");
                try writeReplyJson(w, entry.val);
            }
            try w.writeAll("}");
        },
        .view_node => try writeViewJson(w, val),
        else => return error.Unrepresentable,
    }
}

// ── tests ───────────────────────────────────────────────

const testing = std.testing;

fn viewJson(gpa: std.mem.Allocator, val: *const Value) ![]u8 {
    var aw = std.Io.Writer.Allocating.init(gpa);
    errdefer aw.deinit();
    try writeViewJson(&aw.writer, val);
    return aw.toOwnedSlice();
}

const all_controls = blk: {
    var s: [31]u8 = undefined;
    for (&s, 1..) |*c, i| c.* = i;
    break :blk s;
};

test "every control character in a view text is escaped, and the JSON parses back to it" {
    const gpa = testing.allocator;
    const text: Value = .{ .string = "a\rb" ++ all_controls ++ "\"q\" \\ end" };
    const json = try viewJson(gpa, &text);
    defer gpa.free(json);
    for (json) |c| try testing.expect(c >= 0x20);
    const parsed = try std.json.parseFromSlice(struct { text: []const u8 }, gpa, json, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings(text.string, parsed.value.text);
}

test "an atom and a non-string child are escaped too" {
    const gpa = testing.allocator;
    const atom: Value = .{ .atom = "a\rb\"" };
    const json = try viewJson(gpa, &atom);
    defer gpa.free(json);
    const s = try std.json.parseFromSlice([]const u8, gpa, json, .{});
    defer s.deinit();
    try testing.expectEqualStrings("a\rb\"", s.value);

    // A list's formatted text quotes its strings: the else branch.
    const inner: Value = .{ .string = "say \"hi\"\r" };
    const items = [_]*const Value{&inner};
    const list: Value = .{ .list = &items };
    const lj = try viewJson(gpa, &list);
    defer gpa.free(lj);
    const lp = try std.json.parseFromSlice(struct { text: []const u8 }, gpa, lj, .{});
    defer lp.deinit();
    try testing.expect(std.mem.indexOf(u8, lp.value.text, "say \"hi\"\r") != null);
}

test "a view that cannot be allocated is an error, not a shorter view" {
    // Every allocation point from the first to past the end of the JSON:
    // each one fails the write, none returns cut-off output as success.
    const text: Value = .{ .string = "x" ** 5000 };
    const kids = [_]*const Value{ &text, &text, &text };
    const vn: Value.ViewNode = .{ .tag = "el", .attrs = &.{}, .children = &kids };
    const node: Value = .{ .view_node = &vn };
    var fail_at: usize = 0;
    var succeeded = false;
    while (fail_at < 64) : (fail_at += 1) {
        var fa = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_at });
        var aw = std.Io.Writer.Allocating.init(fa.allocator());
        defer aw.deinit();
        if (writeViewJson(&aw.writer, &node)) {
            try testing.expect(!fa.has_induced_failure);
            try testing.expect(aw.written().len > 15000);
            succeeded = true;
            break;
        } else |err| {
            try testing.expectEqual(error.WriteFailed, err);
            try testing.expect(fa.has_induced_failure);
        }
    }
    try testing.expect(succeeded);
}

test "a formatted value whose write fails deep inside format is still an error" {
    // Value.format swallows its own write errors; the Guard does not.
    const s: Value = .{ .string = "y" ** 3000 };
    const items = [_]*const Value{ &s, &s };
    const list: Value = .{ .list = &items };
    var fa = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 1 });
    var aw = std.Io.Writer.Allocating.init(fa.allocator());
    defer aw.deinit();
    try testing.expectError(error.WriteFailed, writeViewJson(&aw.writer, &list));
}

test "a reply that cannot be written says which: unrepresentable or out of memory" {
    const gpa = testing.allocator;
    var aw = std.Io.Writer.Allocating.init(gpa);
    defer aw.deinit();
    const hole: Value = .hole;
    try testing.expectError(error.Unrepresentable, writeReplyJson(&aw.writer, &hole));

    const s: Value = .{ .string = "z" ** 4000 };
    var fa = testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    var aw2 = std.Io.Writer.Allocating.init(fa.allocator());
    defer aw2.deinit();
    try testing.expectError(error.WriteFailed, writeReplyJson(&aw2.writer, &s));
}

test "the Guard notices a failure that the code writing through it ignored" {
    var small: [8]u8 = undefined;
    var fixed = std.Io.Writer.fixed(&small);
    var g = Guard.init(&fixed, false);
    const w = g.start();
    w.writeAll("0123456789" ** 40) catch {};
    try testing.expectError(error.WriteFailed, g.finish());

    var big: [64]u8 = undefined;
    var fixed2 = std.Io.Writer.fixed(&big);
    var g2 = Guard.init(&fixed2, true);
    const w2 = g2.start();
    w2.writeAll("a\r\"") catch {};
    try g2.finish();
    try testing.expectEqualStrings("a\\r\\\"", fixed2.buffered());
}
