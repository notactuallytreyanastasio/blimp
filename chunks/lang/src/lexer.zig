const std = @import("std");
const Token = @import("token.zig").Token;

pub const Lexer = struct {
    source: []const u8,
    pos: u32,
    line: u32,
    col: u32,

    pub fn init(source: []const u8) Lexer {
        return .{
            .source = source,
            .pos = 0,
            .line = 1,
            .col = 1,
        };
    }

    pub fn next(self: *Lexer) Token {
        self.skipWhitespace();

        if (self.isAtEnd()) {
            return self.makeToken(.eof, "");
        }

        const c = self.peek();

        // Comments
        if (c == '#') {
            self.skipComment();
            return self.next();
        }

        // Newlines
        if (c == '\n') {
            const tok = self.makeToken(.newline, self.source[self.pos .. self.pos + 1]);
            self.advance();
            self.line += 1;
            self.col = 1;
            return tok;
        }

        // String literals
        if (c == '"') return self.lexString();

        // Numbers
        if (isDigit(c)) return self.lexNumber();

        // :: (colon_colon) or :atom or bare :
        if (c == ':' and self.pos + 1 < self.source.len and self.source[self.pos + 1] == ':') {
            const start = self.pos;
            const start_col = self.col;
            self.advance();
            self.advance();
            return .{ .kind = .colon_colon, .lexeme = self.source[start .. start + 2], .line = self.line, .col = start_col };
        }
        if (c == ':' and self.pos + 1 < self.source.len and isAlpha(self.source[self.pos + 1])) {
            return self.lexAtom();
        }

        // Identifiers and keywords
        if (isAlpha(c) or c == '_') return self.lexIdentifier();

        // Operators and delimiters
        return self.lexOperator();
    }

    // -- Private helpers --

    fn skipWhitespace(self: *Lexer) void {
        while (!self.isAtEnd()) {
            const c = self.peek();
            if (c == ' ' or c == '\t' or c == '\r') {
                self.advance();
            } else {
                break;
            }
        }
    }

    fn skipComment(self: *Lexer) void {
        while (!self.isAtEnd() and self.peek() != '\n') {
            self.advance();
        }
    }

    fn lexString(self: *Lexer) Token {
        const start = self.pos;
        const start_col = self.col;
        self.advance(); // skip opening "
        while (!self.isAtEnd() and self.peek() != '"') {
            if (self.peek() == '\\') self.advance(); // skip escape
            self.advance();
        }
        if (!self.isAtEnd()) self.advance(); // skip closing "
        return .{
            .kind = .string,
            .lexeme = self.source[start..self.pos],
            .line = self.line,
            .col = start_col,
        };
    }

    fn lexNumber(self: *Lexer) Token {
        const start = self.pos;
        const start_col = self.col;
        var is_float = false;

        while (!self.isAtEnd() and isDigit(self.peek())) {
            self.advance();
        }
        if (!self.isAtEnd() and self.peek() == '.' and self.pos + 1 < self.source.len and isDigit(self.source[self.pos + 1])) {
            is_float = true;
            self.advance(); // skip .
            while (!self.isAtEnd() and isDigit(self.peek())) {
                self.advance();
            }
        }
        return .{
            .kind = if (is_float) .float else .integer,
            .lexeme = self.source[start..self.pos],
            .line = self.line,
            .col = start_col,
        };
    }

    fn lexAtom(self: *Lexer) Token {
        const start = self.pos;
        const start_col = self.col;
        self.advance(); // skip :
        while (!self.isAtEnd() and (isAlphaNumeric(self.peek()) or self.peek() == '_')) {
            self.advance();
        }
        // Allow ? and ! at end of atoms (Ruby-style predicates/bangs)
        if (!self.isAtEnd() and (self.peek() == '?' or self.peek() == '!')) {
            self.advance();
        }
        return .{
            .kind = .atom,
            .lexeme = self.source[start..self.pos],
            .line = self.line,
            .col = start_col,
        };
    }

    fn lexIdentifier(self: *Lexer) Token {
        const start = self.pos;
        const start_col = self.col;
        const first_char = self.peek();
        while (!self.isAtEnd() and (isAlphaNumeric(self.peek()) or self.peek() == '_')) {
            self.advance();
        }
        // Allow ? and ! at end of identifiers (Ruby-style)
        if (!self.isAtEnd() and (self.peek() == '?' or self.peek() == '!')) {
            self.advance();
        }
        const lexeme = self.source[start..self.pos];

        // Standalone _ is a hole token
        if (std.mem.eql(u8, lexeme, "_")) {
            return .{ .kind = .hole, .lexeme = lexeme, .line = self.line, .col = start_col };
        }

        // Check for keywords
        if (Token.keyword(lexeme)) |kw_kind| {
            return .{ .kind = kw_kind, .lexeme = lexeme, .line = self.line, .col = start_col };
        }

        // PascalCase vs snake_case
        const kind: Token.Kind = if (isUpper(first_char)) .upper_identifier else .identifier;
        return .{ .kind = kind, .lexeme = lexeme, .line = self.line, .col = start_col };
    }

    fn lexOperator(self: *Lexer) Token {
        const start = self.pos;
        const start_col = self.col;
        const c = self.peek();
        self.advance();

        // Two-character operators
        if (!self.isAtEnd()) {
            const next_c = self.peek();
            const two_char: ?Token.Kind = switch (c) {
                '|' => if (next_c == '>') Token.Kind.pipe_arrow else null,
                '<' => if (next_c == '-') Token.Kind.send_arrow else if (next_c == '=') Token.Kind.lt_eq else null,
                '>' => if (next_c == '=') Token.Kind.gt_eq else null,
                '=' => if (next_c == '=') Token.Kind.eq_eq else null,
                '!' => if (next_c == '=') Token.Kind.bang_eq else null,
                '&' => if (next_c == '&') Token.Kind.amp_amp else null,
                '-' => if (next_c == '>') Token.Kind.arrow else null,
                else => null,
            };
            if (two_char) |kind| {
                self.advance();
                return .{ .kind = kind, .lexeme = self.source[start..self.pos], .line = self.line, .col = start_col };
            }
            // || needs special handling since | is also a valid single-char token
            if (c == '|' and next_c == '|') {
                self.advance();
                return .{ .kind = .pipe_pipe, .lexeme = self.source[start..self.pos], .line = self.line, .col = start_col };
            }
        }

        // Single-character tokens
        const kind: Token.Kind = switch (c) {
            '+' => .plus,
            '-' => .minus,
            '*' => .star,
            '/' => .slash,
            '=' => .eq,
            '<' => .lt,
            '>' => .gt,
            '!' => .bang,
            '|' => .pipe,
            '.' => {
                if (self.pos < self.source.len and self.source[self.pos] == '.') {
                    self.pos += 1;
                    if (self.pos < self.source.len and self.source[self.pos] == '.') {
                        self.pos += 1;
                        return self.makeToken(.dot_dot_dot, "...");
                    }
                    return self.makeToken(.dot_dot, "..");
                }
                return self.makeToken(.dot, ".");
            },
            '(' => .lparen,
            ')' => .rparen,
            '{' => .lbrace,
            '}' => .rbrace,
            '[' => .lbracket,
            ']' => .rbracket,
            ',' => .comma,
            ':' => .colon,
            '%' => .percent,
            else => .invalid,
        };
        return .{ .kind = kind, .lexeme = self.source[start..self.pos], .line = self.line, .col = start_col };
    }

    fn peek(self: *const Lexer) u8 {
        return self.source[self.pos];
    }

    fn advance(self: *Lexer) void {
        self.pos += 1;
        self.col += 1;
    }

    fn isAtEnd(self: *const Lexer) bool {
        return self.pos >= self.source.len;
    }

    fn isDigit(c: u8) bool {
        return c >= '0' and c <= '9';
    }

    fn isAlpha(c: u8) bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
    }

    fn isUpper(c: u8) bool {
        return c >= 'A' and c <= 'Z';
    }

    fn isAlphaNumeric(c: u8) bool {
        return isAlpha(c) or isDigit(c);
    }

    fn makeToken(self: *const Lexer, kind: Token.Kind, lexeme: []const u8) Token {
        return .{
            .kind = kind,
            .lexeme = lexeme,
            .line = self.line,
            .col = self.col,
        };
    }
};

// ============================================================
// Tests
// ============================================================

test "lex keywords" {
    var lexer = Lexer.init("actor do end state on become reply when def fn");
    const expected = [_]Token.Kind{
        .kw_actor, .kw_do, .kw_end, .kw_state, .kw_on,
        .kw_become, .kw_reply, .kw_when, .kw_def, .kw_fn,
    };
    for (expected) |exp| {
        const tok = lexer.next();
        try std.testing.expectEqual(exp, tok.kind);
    }
    try std.testing.expectEqual(Token.Kind.eof, lexer.next().kind);
}

test "lex literals" {
    var lexer = Lexer.init("42 3.14 \"hello\" :ok true false nil");
    try std.testing.expectEqual(Token.Kind.integer, lexer.next().kind);
    try std.testing.expectEqual(Token.Kind.float, lexer.next().kind);
    try std.testing.expectEqual(Token.Kind.string, lexer.next().kind);
    try std.testing.expectEqual(Token.Kind.atom, lexer.next().kind);
    try std.testing.expectEqual(Token.Kind.true_lit, lexer.next().kind);
    try std.testing.expectEqual(Token.Kind.false_lit, lexer.next().kind);
    try std.testing.expectEqual(Token.Kind.nil_lit, lexer.next().kind);
}

test "lex identifiers and actor names" {
    var lexer = Lexer.init("counter Checkout my_var");
    const t1 = lexer.next();
    try std.testing.expectEqual(Token.Kind.identifier, t1.kind);
    try std.testing.expectEqualStrings("counter", t1.lexeme);

    const t2 = lexer.next();
    try std.testing.expectEqual(Token.Kind.upper_identifier, t2.kind);
    try std.testing.expectEqualStrings("Checkout", t2.lexeme);

    const t3 = lexer.next();
    try std.testing.expectEqual(Token.Kind.identifier, t3.kind);
    try std.testing.expectEqualStrings("my_var", t3.lexeme);
}

test "lex two-character operators" {
    var lexer = Lexer.init("|> <- <= >= == != && ||");
    try std.testing.expectEqual(Token.Kind.pipe_arrow, lexer.next().kind);
    try std.testing.expectEqual(Token.Kind.send_arrow, lexer.next().kind);
    try std.testing.expectEqual(Token.Kind.lt_eq, lexer.next().kind);
    try std.testing.expectEqual(Token.Kind.gt_eq, lexer.next().kind);
    try std.testing.expectEqual(Token.Kind.eq_eq, lexer.next().kind);
    try std.testing.expectEqual(Token.Kind.bang_eq, lexer.next().kind);
    try std.testing.expectEqual(Token.Kind.amp_amp, lexer.next().kind);
    try std.testing.expectEqual(Token.Kind.pipe_pipe, lexer.next().kind);
}

test "lex single-character operators and delimiters" {
    var lexer = Lexer.init("+ - * / = < > ( ) { } [ ] , : % . |");
    const expected = [_]Token.Kind{
        .plus, .minus, .star, .slash, .eq, .lt, .gt,
        .lparen, .rparen, .lbrace, .rbrace, .lbracket, .rbracket,
        .comma, .colon, .percent, .dot, .pipe,
    };
    for (expected) |exp| {
        const tok = lexer.next();
        try std.testing.expectEqual(exp, tok.kind);
    }
}

test "lex skips comments" {
    var lexer = Lexer.init("actor # this is a comment\nCounter");
    try std.testing.expectEqual(Token.Kind.kw_actor, lexer.next().kind);
    try std.testing.expectEqual(Token.Kind.newline, lexer.next().kind);
    const tok = lexer.next();
    try std.testing.expectEqual(Token.Kind.upper_identifier, tok.kind);
    try std.testing.expectEqualStrings("Counter", tok.lexeme);
}

test "lex tracks line and column" {
    var lexer = Lexer.init("actor Counter\n  state count: 0");
    const t1 = lexer.next(); // actor
    try std.testing.expectEqual(@as(u32, 1), t1.line);
    try std.testing.expectEqual(@as(u32, 1), t1.col);

    _ = lexer.next(); // Counter
    _ = lexer.next(); // newline

    const t4 = lexer.next(); // state
    try std.testing.expectEqual(@as(u32, 2), t4.line);
    try std.testing.expectEqual(@as(u32, 3), t4.col);
}

test "lex atom lexeme includes colon" {
    var lexer = Lexer.init(":increment");
    const tok = lexer.next();
    try std.testing.expectEqual(Token.Kind.atom, tok.kind);
    try std.testing.expectEqualStrings(":increment", tok.lexeme);
}

test "lex complete actor definition" {
    var lexer = Lexer.init(
        \\actor Counter do
        \\  state count: 0
        \\  on :increment do
        \\    become count: count + 1
        \\    reply :ok
        \\  end
        \\end
    );

    // actor Counter do\n
    try std.testing.expectEqual(Token.Kind.kw_actor, lexer.next().kind);
    try std.testing.expectEqual(Token.Kind.upper_identifier, lexer.next().kind);
    try std.testing.expectEqual(Token.Kind.kw_do, lexer.next().kind);
    try std.testing.expectEqual(Token.Kind.newline, lexer.next().kind);

    // state count: 0\n
    try std.testing.expectEqual(Token.Kind.kw_state, lexer.next().kind);
    try std.testing.expectEqual(Token.Kind.identifier, lexer.next().kind);
    try std.testing.expectEqual(Token.Kind.colon, lexer.next().kind);
    try std.testing.expectEqual(Token.Kind.integer, lexer.next().kind);
    try std.testing.expectEqual(Token.Kind.newline, lexer.next().kind);

    // on :increment do\n
    try std.testing.expectEqual(Token.Kind.kw_on, lexer.next().kind);
    try std.testing.expectEqual(Token.Kind.atom, lexer.next().kind);
    try std.testing.expectEqual(Token.Kind.kw_do, lexer.next().kind);
    try std.testing.expectEqual(Token.Kind.newline, lexer.next().kind);

    // become count: count + 1\n
    try std.testing.expectEqual(Token.Kind.kw_become, lexer.next().kind);
    try std.testing.expectEqual(Token.Kind.identifier, lexer.next().kind);
    try std.testing.expectEqual(Token.Kind.colon, lexer.next().kind);
    try std.testing.expectEqual(Token.Kind.identifier, lexer.next().kind);
    try std.testing.expectEqual(Token.Kind.plus, lexer.next().kind);
    try std.testing.expectEqual(Token.Kind.integer, lexer.next().kind);
    try std.testing.expectEqual(Token.Kind.newline, lexer.next().kind);

    // reply :ok\n
    try std.testing.expectEqual(Token.Kind.kw_reply, lexer.next().kind);
    try std.testing.expectEqual(Token.Kind.atom, lexer.next().kind);
    try std.testing.expectEqual(Token.Kind.newline, lexer.next().kind);

    // end\n
    try std.testing.expectEqual(Token.Kind.kw_end, lexer.next().kind);
    try std.testing.expectEqual(Token.Kind.newline, lexer.next().kind);

    // end
    try std.testing.expectEqual(Token.Kind.kw_end, lexer.next().kind);
    try std.testing.expectEqual(Token.Kind.eof, lexer.next().kind);
}

test "lex standalone underscore as hole" {
    var lexer = Lexer.init("_ _foo _");
    // First _ is standalone -> hole
    const t1 = lexer.next();
    try std.testing.expectEqual(Token.Kind.hole, t1.kind);
    try std.testing.expectEqualStrings("_", t1.lexeme);

    // _foo is an identifier (starts with _ but has more chars)
    const t2 = lexer.next();
    try std.testing.expectEqual(Token.Kind.identifier, t2.kind);
    try std.testing.expectEqualStrings("_foo", t2.lexeme);

    // Last _ is standalone -> hole
    const t3 = lexer.next();
    try std.testing.expectEqual(Token.Kind.hole, t3.kind);
    try std.testing.expectEqualStrings("_", t3.lexeme);

    try std.testing.expectEqual(Token.Kind.eof, lexer.next().kind);
}

test "lex arrow operator" {
    var lexer = Lexer.init("-> <- -");
    const t1 = lexer.next();
    try std.testing.expectEqual(Token.Kind.arrow, t1.kind);
    try std.testing.expectEqualStrings("->", t1.lexeme);

    const t2 = lexer.next();
    try std.testing.expectEqual(Token.Kind.send_arrow, t2.kind);
    try std.testing.expectEqualStrings("<-", t2.lexeme);

    const t3 = lexer.next();
    try std.testing.expectEqual(Token.Kind.minus, t3.kind);
    try std.testing.expectEqualStrings("-", t3.lexeme);

    try std.testing.expectEqual(Token.Kind.eof, lexer.next().kind);
}

test "lex situation keyword" {
    var lexer = Lexer.init("situation x do end");
    try std.testing.expectEqual(Token.Kind.kw_situation, lexer.next().kind);
    try std.testing.expectEqual(Token.Kind.identifier, lexer.next().kind);
    try std.testing.expectEqual(Token.Kind.kw_do, lexer.next().kind);
    try std.testing.expectEqual(Token.Kind.kw_end, lexer.next().kind);
    try std.testing.expectEqual(Token.Kind.eof, lexer.next().kind);
}

test "lex case keyword" {
    var lexer = Lexer.init("case x do end");
    try std.testing.expectEqual(Token.Kind.kw_case, lexer.next().kind);
    try std.testing.expectEqual(Token.Kind.identifier, lexer.next().kind);
    try std.testing.expectEqual(Token.Kind.kw_do, lexer.next().kind);
    try std.testing.expectEqual(Token.Kind.kw_end, lexer.next().kind);
    try std.testing.expectEqual(Token.Kind.eof, lexer.next().kind);
}
