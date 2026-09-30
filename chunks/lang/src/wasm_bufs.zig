//! The two buffers in wasm_api.zig that are bounded on purpose, and what
//! they do at the bound. Everything else the page reads out of blimp.wasm
//! (view, result, state, reply) grows to fit; these two keep a limit, and
//! when they reach it they say so instead of dropping bytes without a word.
//!
//! Kept apart from wasm_api.zig, which only builds for wasm32, so that
//! `zig build test` exercises them.

const std = @import("std");
const Allocator = std.mem.Allocator;
const List = std.ArrayListUnmanaged(u8);

/// Appended to an error cut at `error_cap`, inside the cap.
pub const truncated_mark = "…(truncated)";
/// An error message longer than this is cut and marked. A message is a
/// sentence or a stack of them; what makes one long is quoted source -- a
/// send's parse error repeats the whole send, args and all.
pub const error_cap = 4096;

/// Cut `list` to at most `cap` bytes, ending in `truncated_mark`, if it is
/// longer. The cut backs up to a UTF-8 boundary so the page can decode it.
pub fn capError(list: *List, cap: usize) void {
    if (list.items.len <= cap) return;
    var cut = cap - truncated_mark.len;
    while (cut > 0 and (list.items[cut] & 0xC0) == 0x80) cut -= 1;
    list.shrinkRetainingCapacity(cut);
    // cut + mark <= cap <= capacity: no allocation, cannot fail
    list.appendSliceAssumeCapacity(truncated_mark);
}

/// The message log getState hands the canvas: one JSON object per message
/// sent, kept across evals and sends until the page reads the state, which
/// empties it.
///
/// It has a cap because a page that sends and never reads the state -- a
/// game drawn from its replies alone, with no canvas -- would otherwise
/// keep every message it ever sent. At the cap the oldest go first (the
/// canvas draws the latest rays), and `dropped` counts them, so a reader
/// sees how many are missing rather than a log that looks complete.
pub const MessageLog = struct {
    /// Entries end to end, no separators.
    bytes: List = .empty,
    /// Where each entry ends in `bytes`.
    ends: std.ArrayListUnmanaged(u32) = .empty,
    /// Entries dropped since the log was last emptied.
    dropped: u32 = 0,
    cap: usize,

    pub fn init(cap: usize) MessageLog {
        return .{ .cap = cap };
    }

    pub fn deinit(self: *MessageLog, gpa: Allocator) void {
        self.bytes.deinit(gpa);
        self.ends.deinit(gpa);
    }

    pub fn clear(self: *MessageLog) void {
        self.bytes.clearRetainingCapacity();
        self.ends.clearRetainingCapacity();
        self.dropped = 0;
    }

    pub fn count(self: *const MessageLog) usize {
        return self.ends.items.len;
    }

    /// The most the log holds between trims: trimming is lazy, so a page
    /// sending thousands of messages between reads moves the log once per
    /// half a cap's worth, not once per message.
    pub fn ceiling(self: *const MessageLog) usize {
        return self.cap + self.cap / 2;
    }

    /// Add one entry. The byte buffer is reserved at the ceiling on first
    /// use and never grows past it, so a page that sends forever and never
    /// reads holds a fixed amount of memory, as it did when the log was a
    /// fixed array. An entry larger than the whole cap, or one that cannot
    /// be stored (out of memory), is counted as dropped.
    pub fn push(self: *MessageLog, gpa: Allocator, entry: []const u8) void {
        if (entry.len > self.cap) {
            self.dropped += 1;
            return;
        }
        if (self.bytes.items.len + entry.len > self.ceiling()) self.trimTo(self.cap - entry.len);
        self.bytes.ensureTotalCapacityPrecise(gpa, self.ceiling()) catch {
            self.dropped += 1;
            return;
        };
        self.ends.ensureUnusedCapacity(gpa, 1) catch {
            self.dropped += 1;
            return;
        };
        self.bytes.appendSliceAssumeCapacity(entry);
        self.ends.appendAssumeCapacity(@intCast(self.bytes.items.len));
    }

    /// Drop the oldest entries until what is left fits the cap.
    pub fn trim(self: *MessageLog) void {
        self.trimTo(self.cap);
    }

    fn trimTo(self: *MessageLog, limit: usize) void {
        const total = self.bytes.items.len;
        if (total <= limit) return;
        var k: usize = 0;
        while (k < self.ends.items.len and total - self.ends.items[k] > limit) k += 1;
        // entries 0..k (inclusive) go
        k += 1;
        if (k > self.ends.items.len) k = self.ends.items.len;
        const start: u32 = self.ends.items[k - 1];
        const keep = total - start;
        std.mem.copyForwards(u8, self.bytes.items[0..keep], self.bytes.items[start..total]);
        self.bytes.shrinkRetainingCapacity(keep);
        const n = self.ends.items.len - k;
        for (0..n) |i| self.ends.items[i] = self.ends.items[i + k] - start;
        self.ends.shrinkRetainingCapacity(n);
        self.dropped += @intCast(k);
    }

    /// The entries as the inside of a JSON array: comma-separated.
    pub fn writeJoined(self: *const MessageLog, w: *std.Io.Writer) std.Io.Writer.Error!void {
        var from: u32 = 0;
        for (self.ends.items, 0..) |end, i| {
            if (i > 0) try w.writeAll(",");
            try w.writeAll(self.bytes.items[from..end]);
            from = end;
        }
    }
};

const testing = std.testing;

fn joined(log: *const MessageLog) ![]u8 {
    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    errdefer aw.deinit();
    try log.writeJoined(&aw.writer);
    return aw.toOwnedSlice();
}

test "a short error is left alone" {
    var l: List = .empty;
    defer l.deinit(testing.allocator);
    try l.appendSlice(testing.allocator, "Parse error at line 1, col 5");
    capError(&l, error_cap);
    try testing.expectEqualStrings("Parse error at line 1, col 5", l.items);
}

test "an error past the cap is cut to the cap and marked" {
    var l: List = .empty;
    defer l.deinit(testing.allocator);
    try l.appendNTimes(testing.allocator, 'x', 10_000);
    capError(&l, error_cap);
    try testing.expectEqual(@as(usize, error_cap), l.items.len);
    try testing.expect(std.mem.endsWith(u8, l.items, truncated_mark));
    try testing.expect(std.unicode.utf8ValidateSlice(l.items));
}

test "an error cut in the middle of a character backs up to the last whole one" {
    var l: List = .empty;
    defer l.deinit(testing.allocator);
    // "é" is two bytes, so a cut at byte 17 lands between them
    for (0..40) |_| try l.appendSlice(testing.allocator, "é");
    capError(&l, 17 + truncated_mark.len);
    try testing.expect(std.unicode.utf8ValidateSlice(l.items));
    try testing.expect(std.mem.endsWith(u8, l.items, truncated_mark));
    try testing.expectEqual(@as(usize, 16 + truncated_mark.len), l.items.len);
}

test "the message log under its cap keeps every entry, comma-joined" {
    var log = MessageLog.init(1024);
    defer log.deinit(testing.allocator);
    log.push(testing.allocator, "{\"n\":1}");
    log.push(testing.allocator, "{\"n\":2}");
    const s = try joined(&log);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("{\"n\":1},{\"n\":2}", s);
    try testing.expectEqual(@as(u32, 0), log.dropped);
}

test "the message log past its cap drops the oldest and counts them" {
    var log = MessageLog.init(100);
    defer log.deinit(testing.allocator);
    var buf: [16]u8 = undefined;
    // 1000 entries of 9 bytes each; 11 of them fit in 100
    for (0..1000) |i| log.push(testing.allocator, try std.fmt.bufPrint(&buf, "{{\"n\":{d:0>3}}}", .{i}));
    log.trim();
    try testing.expect(log.bytes.items.len <= 100);
    try testing.expectEqual(@as(usize, 1000), log.count() + log.dropped);
    const s = try joined(&log);
    defer testing.allocator.free(s);
    // the newest are the ones kept, whole
    try testing.expect(std.mem.endsWith(u8, s, "{\"n\":999}"));
    try testing.expect(std.mem.startsWith(u8, s, "{\"n\":989}"));
    try testing.expectEqual(@as(u32, 989), log.dropped);
    log.clear();
    try testing.expectEqual(@as(u32, 0), log.dropped);
    try testing.expectEqual(@as(usize, 0), log.count());
}

test "an entry bigger than the whole cap is dropped and counted, not kept in part" {
    var log = MessageLog.init(8);
    defer log.deinit(testing.allocator);
    log.push(testing.allocator, "{\"a\":1}");
    log.push(testing.allocator, "{\"big\":\"0123456789\"}");
    log.trim();
    try testing.expectEqual(@as(usize, 1), log.count());
    try testing.expectEqual(@as(u32, 1), log.dropped);
    const s = try joined(&log);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("{\"a\":1}", s);
}

test "the log's memory stops growing at its ceiling" {
    var log = MessageLog.init(100);
    defer log.deinit(testing.allocator);
    log.push(testing.allocator, "{\"n\":000}");
    const reserved = log.bytes.capacity;
    try testing.expectEqual(log.ceiling(), reserved);
    var buf: [16]u8 = undefined;
    for (0..10_000) |i| {
        log.push(testing.allocator, try std.fmt.bufPrint(&buf, "{{\"n\":{d:0>3}}}", .{i % 1000}));
        try testing.expect(log.bytes.items.len <= log.ceiling());
    }
    try testing.expectEqual(reserved, log.bytes.capacity);
}
