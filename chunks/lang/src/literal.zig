//! Reading a string literal's lexeme: the pieces both the parser (which does
//! it once) and the pattern matcher need.
const std = @import("std");

/// The lexeme without its surrounding quotes. The lexer keeps them; a
/// string built by hand may not have any.
pub fn stripQuotes(raw: []const u8) []const u8 {
    return if (raw.len >= 2 and raw[0] == '"' and raw[raw.len - 1] == '"')
        raw[1 .. raw.len - 1]
    else
        raw;
}

/// True when `s` has a `#{` that is not written `\#{`.
pub fn hasInterpolation(s: []const u8) bool {
    var i: usize = 0;
    while (i + 1 < s.len) : (i += 1) {
        if (s[i] == '\\') {
            i += 1;
            continue;
        }
        if (s[i] == '#' and s[i + 1] == '{') return true;
    }
    return false;
}

/// The first `#{` or `\#` at or after `from`, or the end of `s`.
pub fn nextInterpOrEscapedHash(s: []const u8, from: usize) usize {
    var j = from;
    while (j + 1 < s.len) {
        if (s[j] == '\\') {
            if (s[j + 1] == '#') return j;
            j += 2; // an escape pair: `\\#{` is a backslash, then `#{`
            continue;
        }
        if (s[j] == '#' and s[j + 1] == '{') return j;
        j += 1;
    }
    return s.len;
}

/// Append `s` to `buf`, turning \n \r \t \e \\ \" and \# into the bytes they
/// name. Any other backslash is kept as written.
pub fn appendUnescaped(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), s: []const u8) error{OutOfMemory}!void {
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\\' and i + 1 < s.len) {
            const byte: ?u8 = switch (s[i + 1]) {
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                'e' => 0x1b,
                '\\' => '\\',
                '"' => '"',
                '#' => '#',
                else => null,
            };
            if (byte) |b| {
                try buf.append(allocator, b);
                i += 2;
                continue;
            }
        }
        try buf.append(allocator, s[i]);
        i += 1;
    }
}
