//! Character-aware string operations: UTF-8 validation and repair, code
//! points, extended grapheme clusters (UAX #29) and Unicode case mapping.
//!
//! Blimp strings are bytes, and `length`, `slice`, `index_of` and friends
//! stay byte operations -- Temper's StringIndex is a byte offset and the site
//! is built on that. This file is what the `utf8_*` and `grapheme*` builtins
//! call. Everything here except `firstInvalid` and `scrub` expects valid
//! UTF-8; the builtins check before calling and raise when it is not.
//!
//! The property tables are generated from the Unicode Character Database by
//! tools/gen_unicode_tables.py; `tables.unicode_version` says which one.

const std = @import("std");
pub const tables = @import("unicode_tables.zig");

const Gcb = tables.Gcb;
const InCB = tables.InCB;

// ---------------------------------------------------------------------------
// Decoding
// ---------------------------------------------------------------------------

/// One step of decoding. When `ok` is false, `len` is the length of the
/// maximal subpart (Unicode 3.9, "U+FFFD Substitution of Maximal Subparts"):
/// the longest prefix of a well-formed sequence found at this position, or 1
/// when the byte cannot start one. That is the unit `scrub` replaces, and the
/// one WHATWG, Python and Elixir's String.replace_invalid replace too.
pub const Step = struct { cp: u21, len: u3, ok: bool };

/// Decode the sequence at s[i]. Well-formed means Table 3-7 of the Unicode
/// standard: no overlongs, no surrogates (ED A0..BF), nothing past U+10FFFF.
pub fn decodeAt(s: []const u8, i: usize) Step {
    const b0 = s[i];
    if (b0 < 0x80) return .{ .cp = b0, .len = 1, .ok = true };
    var need: u3 = undefined;
    var lo: u8 = 0x80;
    var hi: u8 = 0xBF;
    var cp: u21 = undefined;
    switch (b0) {
        0xC2...0xDF => {
            need = 1;
            cp = b0 & 0x1F;
        },
        0xE0 => {
            need = 2;
            lo = 0xA0;
            cp = b0 & 0x0F;
        },
        0xE1...0xEC, 0xEE, 0xEF => {
            need = 2;
            cp = b0 & 0x0F;
        },
        0xED => {
            need = 2;
            hi = 0x9F;
            cp = b0 & 0x0F;
        },
        0xF0 => {
            need = 3;
            lo = 0x90;
            cp = b0 & 0x07;
        },
        0xF1...0xF3 => {
            need = 3;
            cp = b0 & 0x07;
        },
        0xF4 => {
            need = 3;
            hi = 0x8F;
            cp = b0 & 0x07;
        },
        else => return .{ .cp = 0, .len = 1, .ok = false },
    }
    var k: u3 = 1;
    while (k <= need) : (k += 1) {
        if (i + k >= s.len) return .{ .cp = 0, .len = k, .ok = false };
        const b = s[i + k];
        const l: u8 = if (k == 1) lo else 0x80;
        const h: u8 = if (k == 1) hi else 0xBF;
        if (b < l or b > h) return .{ .cp = 0, .len = k, .ok = false };
        cp = (cp << 6) | (b & 0x3F);
    }
    return .{ .cp = cp, .len = need + 1, .ok = true };
}

/// Decode at s[i] where s is known to be valid.
inline fn decodeValid(s: []const u8, i: usize) Step {
    const st = decodeAt(s, i);
    std.debug.assert(st.ok);
    return st;
}

/// Byte offset of the first ill-formed sequence, or null if s is UTF-8.
pub fn firstInvalid(s: []const u8) ?usize {
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] < 0x80) {
            i += 1;
            continue;
        }
        const st = decodeAt(s, i);
        if (!st.ok) return i;
        i += st.len;
    }
    return null;
}

/// s with every maximal subpart of an ill-formed sequence replaced by U+FFFD.
/// Answers s itself when it is already valid.
pub fn scrub(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    const first = firstInvalid(s) orelse return s;
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(allocator, s[0..first]);
    var i = first;
    while (i < s.len) {
        const st = decodeAt(s, i);
        if (st.ok) {
            try out.appendSlice(allocator, s[i .. i + st.len]);
        } else {
            try out.appendSlice(allocator, "\u{FFFD}");
        }
        i += st.len;
    }
    return out.items;
}

// ---------------------------------------------------------------------------
// Code points
// ---------------------------------------------------------------------------

/// Number of code points in valid UTF-8: every byte that is not a
/// continuation byte starts one.
pub fn codepointCount(s: []const u8) usize {
    var n: usize = 0;
    for (s) |b| {
        if (b & 0xC0 != 0x80) n += 1;
    }
    return n;
}

/// Byte offset of code point `n` of valid s, or s.len when there are not
/// that many.
fn codepointOffset(s: []const u8, n: usize) usize {
    var seen: usize = 0;
    for (s, 0..) |b, i| {
        if (b & 0xC0 != 0x80) {
            if (seen == n) return i;
            seen += 1;
        }
    }
    return s.len;
}

/// The `count` code points of valid s starting at code point `start`,
/// shortened at the end of the string. A slice of s, never a copy.
pub fn codepointSlice(s: []const u8, start: usize, count: usize) []const u8 {
    const from = codepointOffset(s, start);
    const to = from + codepointOffset(s[from..], count);
    return s[from..to];
}

// ---------------------------------------------------------------------------
// Properties
// ---------------------------------------------------------------------------

pub const Props = struct { gcb: Gcb, ext_pict: bool, incb: InCB };

fn searchRanges(comptime T: type, rs: []const T, cp: u21) ?usize {
    var lo: usize = 0;
    var hi: usize = rs.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (cp < rs[mid].lo) {
            hi = mid;
        } else if (cp > rs[mid].hi) {
            lo = mid + 1;
        } else return mid;
    }
    return null;
}

pub fn props(cp: u21) Props {
    if (cp < 0x80) {
        const g: Gcb = switch (cp) {
            '\r' => .cr,
            '\n' => .lf,
            0...9, 0x0B, 0x0C, 0x0E...0x1F, 0x7F => .control,
            else => .other,
        };
        return .{ .gcb = g, .ext_pict = false, .incb = .none };
    }
    return .{
        .gcb = if (searchRanges(tables.GcbRange, &tables.gcb_ranges, cp)) |k| tables.gcb_ranges[k].p else .other,
        .ext_pict = searchRanges(tables.Range, &tables.ext_pict_ranges, cp) != null,
        .incb = if (searchRanges(tables.InCBRange, &tables.incb_ranges, cp)) |k| tables.incb_ranges[k].p else .none,
    };
}

// ---------------------------------------------------------------------------
// Extended grapheme clusters, UAX #29 section 3.1.1, rules GB3-GB999.
//
// The rules that look back past the previous character (GB9c, GB11, GB12
// and GB13) are regular expressions over the text before the break, so each
// is carried as a small state updated per code point. The state is not reset
// at a break: the rules are defined over the whole preceding text, and it
// comes out the same, because every sequence they match is itself unbroken.
// ---------------------------------------------------------------------------

const EmojiState = enum { none, pict, pict_zwj };
const IncbState = enum { none, consonant, linker };

pub const GraphemeIterator = struct {
    s: []const u8,
    i: usize = 0,
    prev: Gcb = .other,
    /// Regional indicators immediately before i.
    ri_run: usize = 0,
    /// ExtPict Extend* (pict), or ExtPict Extend* ZWJ (pict_zwj), just before i.
    emoji: EmojiState = .none,
    /// InCB=Consonant [Extend Linker]* just before i, and whether a Linker
    /// is among them.
    incb: IncbState = .none,

    pub fn init(s: []const u8) GraphemeIterator {
        return .{ .s = s };
    }

    fn feed(self: *GraphemeIterator, p: Props) void {
        self.ri_run = if (p.gcb == .regional_indicator) self.ri_run + 1 else 0;
        self.emoji = if (p.ext_pict)
            .pict
        else if (p.gcb == .extend and self.emoji == .pict)
            .pict
        else if (p.gcb == .zwj and self.emoji == .pict)
            .pict_zwj
        else
            .none;
        self.incb = switch (p.incb) {
            .consonant => .consonant,
            .linker => if (self.incb != .none) .linker else .none,
            .extend => self.incb,
            .none => .none,
        };
        self.prev = p.gcb;
    }

    fn isBreak(self: *const GraphemeIterator, cur: Props) bool {
        const prev = self.prev;
        const c = cur.gcb;
        if (prev == .cr and c == .lf) return false; // GB3
        if (prev == .cr or prev == .lf or prev == .control) return true; // GB4
        if (c == .cr or c == .lf or c == .control) return true; // GB5
        if (prev == .l and (c == .l or c == .v or c == .lv or c == .lvt)) return false; // GB6
        if ((prev == .lv or prev == .v) and (c == .v or c == .t)) return false; // GB7
        if ((prev == .lvt or prev == .t) and c == .t) return false; // GB8
        if (c == .extend or c == .zwj) return false; // GB9
        if (c == .spacing_mark) return false; // GB9a
        if (prev == .prepend) return false; // GB9b
        if (cur.incb == .consonant and self.incb == .linker) return false; // GB9c
        if (prev == .zwj and self.emoji == .pict_zwj and cur.ext_pict) return false; // GB11
        if (prev == .regional_indicator and c == .regional_indicator and self.ri_run % 2 == 1) return false; // GB12, GB13
        return true; // GB999
    }

    /// The next cluster, as a slice of s.
    pub fn next(self: *GraphemeIterator) ?[]const u8 {
        if (self.i >= self.s.len) return null; // GB2
        const start = self.i;
        const first = decodeValid(self.s, self.i);
        self.feed(props(first.cp)); // GB1: always a break before the first
        self.i += first.len;
        while (self.i < self.s.len) {
            const st = decodeValid(self.s, self.i);
            const p = props(st.cp);
            if (self.isBreak(p)) break;
            self.feed(p);
            self.i += st.len;
        }
        return self.s[start..self.i];
    }
};

pub fn graphemeCount(s: []const u8) usize {
    var it = GraphemeIterator.init(s);
    var n: usize = 0;
    while (it.next() != null) n += 1;
    return n;
}

/// The `count` clusters of valid s starting at cluster `start`, shortened at
/// the end. A slice of s.
pub fn graphemeSlice(s: []const u8, start: usize, count: usize) []const u8 {
    var it = GraphemeIterator.init(s);
    var k: usize = 0;
    while (k < start) : (k += 1) {
        if (it.next() == null) return s[s.len..];
    }
    const from = it.i;
    k = 0;
    while (k < count) : (k += 1) {
        if (it.next() == null) break;
    }
    return s[from..it.i];
}

// ---------------------------------------------------------------------------
// Case mapping: the full mappings of SpecialCasing.txt that carry no
// condition, else the simple mappings of UnicodeData.txt. Conditional ones
// (Final_Sigma, and the lt/tr/az language rules) are not applied, which is
// also what Elixir's String.upcase/downcase do in their default mode.
// ---------------------------------------------------------------------------

pub const Case = enum { lower, upper };

fn searchMap(comptime T: type, m: []const T, cp: u21) ?usize {
    var lo: usize = 0;
    var hi: usize = m.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (cp < m[mid].from) {
            hi = mid;
        } else if (cp > m[mid].from) {
            lo = mid + 1;
        } else return mid;
    }
    return null;
}

fn appendCp(out: *std.ArrayList(u8), allocator: std.mem.Allocator, cp: u21) !void {
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &buf) catch unreachable;
    try out.appendSlice(allocator, buf[0..n]);
}

/// Case-map valid s.
pub fn changeCase(allocator: std.mem.Allocator, s: []const u8, which: Case) ![]u8 {
    const full: []const tables.Multi = if (which == .lower) &tables.lower_full else &tables.upper_full;
    const simple: []const tables.Map = if (which == .lower) &tables.lower_simple else &tables.upper_simple;
    var out = try std.ArrayList(u8).initCapacity(allocator, s.len);
    var i: usize = 0;
    while (i < s.len) {
        const b = s[i];
        if (b < 0x80) {
            const mapped: u8 = switch (which) {
                .lower => if (b >= 'A' and b <= 'Z') b + 32 else b,
                .upper => if (b >= 'a' and b <= 'z') b - 32 else b,
            };
            try out.append(allocator, mapped);
            i += 1;
            continue;
        }
        const st = decodeValid(s, i);
        if (searchMap(tables.Multi, full, st.cp)) |k| {
            for (full[k].to[0..full[k].len]) |cp| try appendCp(&out, allocator, cp);
        } else if (searchMap(tables.Map, simple, st.cp)) |k| {
            try appendCp(&out, allocator, simple[k].to);
        } else {
            try out.appendSlice(allocator, s[i .. i + st.len]);
        }
        i += st.len;
    }
    return out.items;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "decodeAt agrees with std.unicode on validity for every 1-3 byte string and a 4-byte sweep" {
    // Every string of one or two bytes, and three bytes over leads E0..EF.
    var buf: [4]u8 = undefined;
    var a: usize = 0;
    while (a < 256) : (a += 1) {
        buf[0] = @intCast(a);
        try testing.expectEqual(std.unicode.utf8ValidateSlice(buf[0..1]), firstInvalid(buf[0..1]) == null);
        var b: usize = 0;
        while (b < 256) : (b += 1) {
            buf[1] = @intCast(b);
            try testing.expectEqual(std.unicode.utf8ValidateSlice(buf[0..2]), firstInvalid(buf[0..2]) == null);
        }
    }
    a = 0xE0;
    while (a <= 0xF4) : (a += 1) {
        buf[0] = @intCast(a);
        var b: usize = 0x70;
        while (b < 0xC8) : (b += 1) {
            buf[1] = @intCast(b);
            var c: usize = 0x70;
            while (c < 0xC8) : (c += 1) {
                buf[2] = @intCast(c);
                try testing.expectEqual(std.unicode.utf8ValidateSlice(buf[0..3]), firstInvalid(buf[0..3]) == null);
                buf[3] = 0x80;
                try testing.expectEqual(std.unicode.utf8ValidateSlice(buf[0..4]), firstInvalid(buf[0..4]) == null);
            }
        }
    }
}

test "firstInvalid names the offset; surrogates, overlongs and > U+10FFFF are invalid" {
    try testing.expectEqual(@as(?usize, null), firstInvalid("héllo ❤️ 👨‍👩‍👧"));
    try testing.expectEqual(@as(?usize, 0), firstInvalid("\xff"));
    try testing.expectEqual(@as(?usize, 2), firstInvalid("ab\xc3"));
    try testing.expectEqual(@as(?usize, 0), firstInvalid("\xed\xa0\x80")); // U+D800
    try testing.expectEqual(@as(?usize, 0), firstInvalid("\xc0\xaf")); // overlong '/'
    try testing.expectEqual(@as(?usize, 0), firstInvalid("\xe0\x80\xaf")); // overlong
    try testing.expectEqual(@as(?usize, 0), firstInvalid("\xf4\x90\x80\x80")); // U+110000
    try testing.expectEqual(@as(?usize, null), firstInvalid("\xf4\x8f\xbf\xbf")); // U+10FFFF
}

test "scrub replaces maximal subparts, as String.replace_invalid does" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // elixir -e 'IO.inspect String.replace_invalid(<<0xe2, 0x9d, ?a, 0xf0, 0x80, 0x80>>)'  => "�a���"
    try testing.expectEqualStrings("\u{FFFD}a\u{FFFD}\u{FFFD}\u{FFFD}", try scrub(a, "\xe2\x9da\xf0\x80\x80"));
    // A surrogate is three subparts, a truncated 4-byte sequence one, an overlong two.
    try testing.expectEqualStrings(
        "a\u{FFFD}\u{FFFD}\u{FFFD}b\u{FFFD}c\u{FFFD}\u{FFFD}d",
        try scrub(a, "a\xed\xa0\x80b\xf4\x80\x80c\xc0\x80d"),
    );
    const ok = "déjà vu";
    try testing.expectEqual(ok.ptr, (try scrub(a, ok)).ptr);
}

test "codepoints count and slice" {
    try testing.expectEqual(@as(usize, 2), codepointCount("❤️")); // U+2764 U+FE0F
    try testing.expectEqual(@as(usize, 5), codepointCount("héllo"));
    try testing.expectEqualStrings("éll", codepointSlice("héllo", 1, 3));
    try testing.expectEqualStrings("lo", codepointSlice("héllo", 3, 99));
    try testing.expectEqualStrings("", codepointSlice("héllo", 9, 2));
    try testing.expectEqualStrings("", codepointSlice("héllo", 1, 0));
}

fn expectClusters(s: []const u8, want: []const []const u8) !void {
    var it = GraphemeIterator.init(s);
    for (want) |w| {
        const got = it.next() orelse return error.TooFewClusters;
        try testing.expectEqualStrings(w, got);
    }
    try testing.expectEqual(@as(?[]const u8, null), it.next());
}

test "graphemes: emoji with presentation selector, ZWJ family, flags, skin tone, combining marks, CRLF, Hangul" {
    try expectClusters("❤️", &.{"❤️"});
    try expectClusters("👨‍👩‍👧‍👦x", &.{ "👨‍👩‍👧‍👦", "x" });
    try expectClusters("🇺🇸🇫🇷🇩", &.{ "🇺🇸", "🇫🇷", "🇩" });
    try expectClusters("👍🏽!", &.{ "👍🏽", "!" });
    try expectClusters("e\u{301}\u{302}a", &.{ "e\u{301}\u{302}", "a" });
    try expectClusters("a\r\nb", &.{ "a", "\r\n", "b" });
    try expectClusters("\u{1100}\u{1161}\u{11A8}", &.{"\u{1100}\u{1161}\u{11A8}"});
    // GB9c: Devanagari KSSA = KA + VIRAMA + SSA is one cluster since Unicode 15.1.
    try expectClusters("क्ष", &.{"क्ष"});
    try expectClusters("", &.{});
}

test "graphemeSlice and count" {
    const s = "a👨‍👩‍👧b🇺🇸c";
    try testing.expectEqual(@as(usize, 5), graphemeCount(s));
    try testing.expectEqualStrings("👨‍👩‍👧b", graphemeSlice(s, 1, 2));
    try testing.expectEqualStrings("🇺🇸c", graphemeSlice(s, 3, 10));
    try testing.expectEqualStrings("", graphemeSlice(s, 5, 1));
    try testing.expectEqualStrings("", graphemeSlice(s, 50, 1));
}

test "every line of the Unicode GraphemeBreakTest.txt this table was built from" {
    const data = @embedFile("testdata/GraphemeBreakTest.txt");
    // The header names the version; it must be the tables' version.
    const want_header = "# GraphemeBreakTest-" ++ tables.unicode_version ++ ".txt";
    try testing.expect(std.mem.startsWith(u8, data, want_header));

    var lines = std.mem.splitScalar(u8, data, '\n');
    var cases: usize = 0;
    var failures: usize = 0;
    while (lines.next()) |raw| {
        const hash = std.mem.indexOfScalar(u8, raw, '#') orelse raw.len;
        const line = std.mem.trim(u8, raw[0..hash], " \t\r");
        if (line.len == 0) continue;
        var text: [128]u8 = undefined;
        var len: usize = 0;
        var boundaries: [64]usize = undefined; // byte offsets where a ÷ sits, excluding 0
        var nb: usize = 0;
        var tokens = std.mem.tokenizeAny(u8, line, " \t");
        while (tokens.next()) |tok| {
            if (std.mem.eql(u8, tok, "÷")) {
                if (len > 0) {
                    boundaries[nb] = len;
                    nb += 1;
                }
            } else if (std.mem.eql(u8, tok, "×")) {} else {
                const cp = try std.fmt.parseInt(u21, tok, 16);
                len += try std.unicode.utf8Encode(cp, text[len..]);
            }
        }
        cases += 1;
        var it = GraphemeIterator.init(text[0..len]);
        var got: [64]usize = undefined;
        var ng: usize = 0;
        while (it.next()) |_| {
            got[ng] = it.i;
            ng += 1;
        }
        if (ng != nb or !std.mem.eql(usize, got[0..ng], boundaries[0..nb])) {
            failures += 1;
            std.debug.print("GraphemeBreakTest: {s}\n  want {any}\n  got  {any}\n", .{ line, boundaries[0..nb], got[0..ng] });
        }
    }
    try testing.expectEqual(@as(usize, 766), cases);
    try testing.expectEqual(@as(usize, 0), failures);
}

test "case mapping: Latin-1, Latin Extended, Greek, Cyrillic, Armenian, full mappings" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("ÀÉÎÕÜ ÇÑ ÆØÅ", try changeCase(a, "àéîõü çñ æøå", .upper));
    try testing.expectEqualStrings("àéîõü", try changeCase(a, "ÀÉÎÕÜ", .lower));
    try testing.expectEqualStrings("STRASSE", try changeCase(a, "straße", .upper));
    try testing.expectEqualStrings("ÿ", try changeCase(a, "Ÿ", .lower)); // U+0178 -> U+00FF
    try testing.expectEqualStrings("ŁÓDŹ ŐŰ", try changeCase(a, "łódź őű", .upper));
    try testing.expectEqualStrings("ΑΘΗΝΑ", try changeCase(a, "αθηνα", .upper));
    // No Final_Sigma: every capital sigma goes to σ, as in Elixir's default mode.
    try testing.expectEqualStrings("σασ", try changeCase(a, "ΣΑΣ", .lower));
    try testing.expectEqualStrings("москва", try changeCase(a, "МОСКВА", .lower));
    try testing.expectEqualStrings("ЁЖИК", try changeCase(a, "ёжик", .upper));
    // İ has an unconditional full lowercase: i + COMBINING DOT ABOVE.
    try testing.expectEqualStrings("i\u{307}stanbul", try changeCase(a, "İstanbul", .lower));
    // ı (dotless) uppercases to I; I lowercases to i (no Turkish tailoring).
    try testing.expectEqualStrings("I", try changeCase(a, "ı", .upper));
    try testing.expectEqualStrings("FI", try changeCase(a, "ﬁ", .upper));
    try testing.expectEqualStrings("ՄՆ ԵՒ", try changeCase(a, "ﬓ և", .upper));
    try testing.expectEqualStrings("日本語 ❤️", try changeCase(a, "日本語 ❤️", .upper));
}
