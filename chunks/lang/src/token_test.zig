/// Tests for token.zig - run with: zig test src/token_test.zig -target x86_64-macos
const std = @import("std");
const Token = @import("token.zig").Token;

// ============================================================
// Token.keyword() - maps lexemes to keyword kinds
// ============================================================

test "keyword: actor" {
    const k = Token.keyword("actor");
    try std.testing.expect(k != null);
    try std.testing.expectEqual(Token.Kind.kw_actor, k.?);
}

test "keyword: do" {
    const k = Token.keyword("do");
    try std.testing.expect(k != null);
    try std.testing.expectEqual(Token.Kind.kw_do, k.?);
}

test "keyword: end" {
    const k = Token.keyword("end");
    try std.testing.expect(k != null);
    try std.testing.expectEqual(Token.Kind.kw_end, k.?);
}

test "keyword: state" {
    const k = Token.keyword("state");
    try std.testing.expect(k != null);
    try std.testing.expectEqual(Token.Kind.kw_state, k.?);
}

test "keyword: on" {
    const k = Token.keyword("on");
    try std.testing.expect(k != null);
    try std.testing.expectEqual(Token.Kind.kw_on, k.?);
}

test "keyword: become" {
    const k = Token.keyword("become");
    try std.testing.expect(k != null);
    try std.testing.expectEqual(Token.Kind.kw_become, k.?);
}

test "keyword: reply" {
    const k = Token.keyword("reply");
    try std.testing.expect(k != null);
    try std.testing.expectEqual(Token.Kind.kw_reply, k.?);
}

test "keyword: when" {
    const k = Token.keyword("when");
    try std.testing.expect(k != null);
    try std.testing.expectEqual(Token.Kind.kw_when, k.?);
}

test "keyword: bubbles" {
    const k = Token.keyword("bubbles");
    try std.testing.expect(k != null);
    try std.testing.expectEqual(Token.Kind.kw_bubbles, k.?);
}

test "keyword: bubble" {
    const k = Token.keyword("bubble");
    try std.testing.expect(k != null);
    try std.testing.expectEqual(Token.Kind.kw_bubble, k.?);
}

test "keyword: def" {
    const k = Token.keyword("def");
    try std.testing.expect(k != null);
    try std.testing.expectEqual(Token.Kind.kw_def, k.?);
}

test "keyword: fn" {
    const k = Token.keyword("fn");
    try std.testing.expect(k != null);
    try std.testing.expectEqual(Token.Kind.kw_fn, k.?);
}

test "keyword: situation" {
    const k = Token.keyword("situation");
    try std.testing.expect(k != null);
    try std.testing.expectEqual(Token.Kind.kw_situation, k.?);
}

test "keyword: case" {
    const k = Token.keyword("case");
    try std.testing.expect(k != null);
    try std.testing.expectEqual(Token.Kind.kw_case, k.?);
}

test "keyword: orelse" {
    const k = Token.keyword("orelse");
    try std.testing.expect(k != null);
    try std.testing.expectEqual(Token.Kind.kw_orelse, k.?);
}

test "keyword: spawn" {
    const k = Token.keyword("spawn");
    try std.testing.expect(k != null);
    try std.testing.expectEqual(Token.Kind.kw_spawn, k.?);
}

test "keyword: self" {
    const k = Token.keyword("self");
    try std.testing.expect(k != null);
    try std.testing.expectEqual(Token.Kind.kw_self, k.?);
}

test "keyword: try" {
    const k = Token.keyword("try");
    try std.testing.expect(k != null);
    try std.testing.expectEqual(Token.Kind.kw_try, k.?);
}

test "keyword: catch" {
    const k = Token.keyword("catch");
    try std.testing.expect(k != null);
    try std.testing.expectEqual(Token.Kind.kw_catch, k.?);
}

test "keyword: for" {
    const k = Token.keyword("for");
    try std.testing.expect(k != null);
    try std.testing.expectEqual(Token.Kind.kw_for, k.?);
}

test "keyword: in" {
    const k = Token.keyword("in");
    try std.testing.expect(k != null);
    try std.testing.expectEqual(Token.Kind.kw_in, k.?);
}

test "keyword: true maps to true_lit" {
    const k = Token.keyword("true");
    try std.testing.expect(k != null);
    try std.testing.expectEqual(Token.Kind.true_lit, k.?);
}

test "keyword: false maps to false_lit" {
    const k = Token.keyword("false");
    try std.testing.expect(k != null);
    try std.testing.expectEqual(Token.Kind.false_lit, k.?);
}

test "keyword: nil maps to nil_lit" {
    const k = Token.keyword("nil");
    try std.testing.expect(k != null);
    try std.testing.expectEqual(Token.Kind.nil_lit, k.?);
}

test "keyword: non-keyword returns null" {
    try std.testing.expect(Token.keyword("foo") == null);
}

test "keyword: identifier-like returns null" {
    try std.testing.expect(Token.keyword("counter") == null);
}

test "keyword: empty string returns null" {
    try std.testing.expect(Token.keyword("") == null);
}

test "keyword: partial keyword returns null" {
    try std.testing.expect(Token.keyword("act") == null);
}

test "keyword: uppercase variant returns null" {
    try std.testing.expect(Token.keyword("Actor") == null);
}

test "keyword: case sensitive - ACTOR returns null" {
    try std.testing.expect(Token.keyword("ACTOR") == null);
}

// ============================================================
// Token struct fields
// ============================================================

test "Token struct has expected fields" {
    const tok = Token{
        .kind = .identifier,
        .lexeme = "hello",
        .line = 3,
        .col = 5,
    };
    try std.testing.expectEqual(Token.Kind.identifier, tok.kind);
    try std.testing.expectEqualStrings("hello", tok.lexeme);
    try std.testing.expectEqual(@as(u32, 3), tok.line);
    try std.testing.expectEqual(@as(u32, 5), tok.col);
}

test "Token eof kind" {
    const tok = Token{ .kind = .eof, .lexeme = "", .line = 1, .col = 0 };
    try std.testing.expectEqual(Token.Kind.eof, tok.kind);
}

test "Token newline kind" {
    const tok = Token{ .kind = .newline, .lexeme = "\n", .line = 1, .col = 0 };
    try std.testing.expectEqual(Token.Kind.newline, tok.kind);
}
