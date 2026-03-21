const std = @import("std");
const Token = @import("token.zig").Token;
const Lexer = @import("lexer.zig").Lexer;
const ast = @import("ast.zig");
const Node = ast.Node;
const Loc = ast.Loc;

pub const ParseError = error{
    UnexpectedToken,
    UnexpectedEof,
    InvalidNumber,
    OutOfMemory,
};

pub const Parser = struct {
    lexer: Lexer,
    current: Token,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, source: []const u8) Parser {
        var lexer = Lexer.init(source);
        const first = lexer.next();
        return .{
            .lexer = lexer,
            .current = first,
            .allocator = allocator,
        };
    }

    /// Parse a complete Blimp source file (sequence of top-level definitions).
    pub fn parseFile(self: *Parser) ParseError![]const Node {
        var nodes: std.ArrayList(Node) = .empty;
        self.skipNewlines();
        while (self.current.kind != .eof) {
            const node = try self.parseTopLevel();
            nodes.append(self.allocator, node) catch return error.OutOfMemory;
            self.skipNewlines();
        }
        return nodes.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
    }

    /// Parse a top-level construct (currently just actor definitions).
    fn parseTopLevel(self: *Parser) ParseError!Node {
        return switch (self.current.kind) {
            .kw_actor => self.parseActorDef(),
            else => error.UnexpectedToken,
        };
    }

    /// Parse: actor Name do ... end
    fn parseActorDef(self: *Parser) ParseError!Node {
        const loc = self.currentLoc();
        try self.expect(.kw_actor);
        const name = self.current.lexeme;
        try self.expect(.upper_identifier);
        try self.expect(.kw_do);
        self.skipNewlines();

        var body: std.ArrayList(Node) = .empty;
        while (self.current.kind != .kw_end and self.current.kind != .eof) {
            const stmt = try self.parseActorBody();
            body.append(self.allocator, stmt) catch return error.OutOfMemory;
            self.skipNewlines();
        }
        try self.expect(.kw_end);

        return Node{
            .kind = .{ .actor_def = .{
                .name = name,
                .body = body.toOwnedSlice(self.allocator) catch return error.OutOfMemory,
            } },
            .loc = loc,
        };
    }

    /// Parse a statement inside an actor body.
    fn parseActorBody(self: *Parser) ParseError!Node {
        return switch (self.current.kind) {
            .kw_state => self.parseStateDef(),
            .kw_on => self.parseMessageHandler(),
            .kw_become => self.parseBecomeStmt(),
            .kw_reply => self.parseReplyStmt(),
            else => self.parseExpressionStatement(),
        };
    }

    /// Parse: state name: Type :: default, name: Type :: default
    /// Also supports untyped: state name: value (for backwards compat)
    fn parseStateDef(self: *Parser) ParseError!Node {
        const loc = self.currentLoc();
        try self.expect(.kw_state);
        const fields = try self.parseTypedKeyValueList();
        return Node{
            .kind = .{ .state_def = .{ .fields = fields } },
            .loc = loc,
        };
    }

    /// Parse: on :message(params) do ... end
    fn parseMessageHandler(self: *Parser) ParseError!Node {
        const loc = self.currentLoc();
        try self.expect(.kw_on);

        // Expect atom for message name
        if (self.current.kind != .atom) return error.UnexpectedToken;
        const raw_name = self.current.lexeme;
        // Strip leading : from atom
        const name = if (raw_name.len > 0 and raw_name[0] == ':') raw_name[1..] else raw_name;
        self.advance();

        // Optional parameter list
        var params: std.ArrayList([]const u8) = .empty;
        if (self.current.kind == .lparen) {
            self.advance();
            while (self.current.kind != .rparen and self.current.kind != .eof) {
                if (self.current.kind != .identifier) return error.UnexpectedToken;
                params.append(self.allocator, self.current.lexeme) catch return error.OutOfMemory;
                self.advance();
                if (self.current.kind == .comma) self.advance();
            }
            try self.expect(.rparen);
        }

        try self.expect(.kw_do);
        self.skipNewlines();

        // Parse body until end
        var body: std.ArrayList(Node) = .empty;
        while (self.current.kind != .kw_end and self.current.kind != .eof) {
            const stmt = try self.parseActorBody();
            body.append(self.allocator, stmt) catch return error.OutOfMemory;
            self.skipNewlines();
        }
        try self.expect(.kw_end);

        return Node{
            .kind = .{ .message_handler = .{
                .name = name,
                .params = params.toOwnedSlice(self.allocator) catch return error.OutOfMemory,
                .body = body.toOwnedSlice(self.allocator) catch return error.OutOfMemory,
            } },
            .loc = loc,
        };
    }

    /// Parse: become key: value, key: value
    fn parseBecomeStmt(self: *Parser) ParseError!Node {
        const loc = self.currentLoc();
        try self.expect(.kw_become);
        const fields = try self.parseKeyValueList();
        return Node{
            .kind = .{ .become_stmt = .{ .fields = fields } },
            .loc = loc,
        };
    }

    /// Parse: reply expression
    fn parseReplyStmt(self: *Parser) ParseError!Node {
        const loc = self.currentLoc();
        try self.expect(.kw_reply);
        const value = try self.parseExpression();
        const value_ptr = self.allocator.create(Node) catch return error.OutOfMemory;
        value_ptr.* = value;
        return Node{
            .kind = .{ .reply_stmt = .{ .value = value_ptr } },
            .loc = loc,
        };
    }

    /// Parse an expression used as a statement (e.g., a function call or assignment).
    fn parseExpressionStatement(self: *Parser) ParseError!Node {
        const expr = try self.parseExpression();
        // Check for assignment: identifier = expression
        if (self.current.kind == .eq) {
            if (expr.kind == .identifier) {
                self.advance();
                const value = try self.parseExpression();
                const value_ptr = self.allocator.create(Node) catch return error.OutOfMemory;
                value_ptr.* = value;
                return Node{
                    .kind = .{ .assign_stmt = .{
                        .name = expr.kind.identifier.name,
                        .value = value_ptr,
                    } },
                    .loc = expr.loc,
                };
            }
        }
        return expr;
    }

    // ============================================================
    // Expression parsing (Pratt / precedence climbing)
    // ============================================================

    fn parseExpression(self: *Parser) ParseError!Node {
        return self.parsePipe();
    }

    /// Parse pipe expressions: left-associative, lowest precedence among binary ops.
    /// a |> b(_, x) |> c(_) parses as (a |> b(_, x)) |> c(_)
    fn parsePipe(self: *Parser) ParseError!Node {
        var left = try self.parseBinaryOr();
        while (self.current.kind == .pipe_arrow) {
            self.advance();
            const right = try self.parseBinaryOr();
            const left_ptr = self.allocator.create(Node) catch return error.OutOfMemory;
            left_ptr.* = left;
            const right_ptr = self.allocator.create(Node) catch return error.OutOfMemory;
            right_ptr.* = right;
            left = Node{
                .kind = .{ .pipe_expr = .{
                    .left = left_ptr,
                    .right = right_ptr,
                } },
                .loc = left.loc,
            };
        }
        return left;
    }

    fn parseBinaryOr(self: *Parser) ParseError!Node {
        var left = try self.parseBinaryAnd();
        while (self.current.kind == .pipe_pipe) {
            self.advance();
            const right = try self.parseBinaryAnd();
            left = try self.makeBinaryOp(.or_op, left, right);
        }
        return left;
    }

    fn parseBinaryAnd(self: *Parser) ParseError!Node {
        var left = try self.parseComparison();
        while (self.current.kind == .amp_amp) {
            self.advance();
            const right = try self.parseComparison();
            left = try self.makeBinaryOp(.and_op, left, right);
        }
        return left;
    }

    fn parseComparison(self: *Parser) ParseError!Node {
        var left = try self.parseAddSub();
        const op: ?Node.BinaryOp.Op = switch (self.current.kind) {
            .eq_eq => .eq,
            .bang_eq => .neq,
            .lt => .lt,
            .gt => .gt,
            .lt_eq => .lte,
            .gt_eq => .gte,
            else => null,
        };
        if (op) |o| {
            self.advance();
            const right = try self.parseAddSub();
            left = try self.makeBinaryOp(o, left, right);
        }
        return left;
    }

    fn parseAddSub(self: *Parser) ParseError!Node {
        var left = try self.parseMulDiv();
        while (self.current.kind == .plus or self.current.kind == .minus) {
            const op: Node.BinaryOp.Op = if (self.current.kind == .plus) .add else .sub;
            self.advance();
            const right = try self.parseMulDiv();
            left = try self.makeBinaryOp(op, left, right);
        }
        return left;
    }

    fn parseMulDiv(self: *Parser) ParseError!Node {
        var left = try self.parseUnary();
        while (self.current.kind == .star or self.current.kind == .slash) {
            const op: Node.BinaryOp.Op = if (self.current.kind == .star) .mul else .div;
            self.advance();
            const right = try self.parseUnary();
            left = try self.makeBinaryOp(op, left, right);
        }
        return left;
    }

    fn parseUnary(self: *Parser) ParseError!Node {
        if (self.current.kind == .minus) {
            const loc = self.currentLoc();
            self.advance();
            const operand = try self.parsePostfix();
            const operand_ptr = self.allocator.create(Node) catch return error.OutOfMemory;
            operand_ptr.* = operand;
            return Node{
                .kind = .{ .unary_op = .{ .op = .negate, .operand = operand_ptr } },
                .loc = loc,
            };
        }
        if (self.current.kind == .bang) {
            const loc = self.currentLoc();
            self.advance();
            const operand = try self.parsePostfix();
            const operand_ptr = self.allocator.create(Node) catch return error.OutOfMemory;
            operand_ptr.* = operand;
            return Node{
                .kind = .{ .unary_op = .{ .op = .not, .operand = operand_ptr } },
                .loc = loc,
            };
        }
        return self.parsePostfix();
    }

    fn parsePostfix(self: *Parser) ParseError!Node {
        var left = try self.parsePrimary();
        // Dot access: expr.field
        while (self.current.kind == .dot) {
            self.advance();
            if (self.current.kind != .identifier) return error.UnexpectedToken;
            const field = self.current.lexeme;
            self.advance();
            const left_ptr = self.allocator.create(Node) catch return error.OutOfMemory;
            left_ptr.* = left;
            left = Node{
                .kind = .{ .dot_access = .{ .object = left_ptr, .field = field } },
                .loc = left.loc,
            };
        }
        return left;
    }

    fn parsePrimary(self: *Parser) ParseError!Node {
        const loc = self.currentLoc();
        switch (self.current.kind) {
            .integer => {
                const value = std.fmt.parseInt(i64, self.current.lexeme, 10) catch return error.InvalidNumber;
                self.advance();
                return Node{ .kind = .{ .integer_lit = .{ .value = value } }, .loc = loc };
            },
            .float => {
                const value = std.fmt.parseFloat(f64, self.current.lexeme) catch return error.InvalidNumber;
                self.advance();
                return Node{ .kind = .{ .float_lit = .{ .value = value } }, .loc = loc };
            },
            .string => {
                const value = self.current.lexeme;
                self.advance();
                return Node{ .kind = .{ .string_lit = .{ .value = value } }, .loc = loc };
            },
            .atom => {
                const raw = self.current.lexeme;
                const name = if (raw.len > 0 and raw[0] == ':') raw[1..] else raw;
                self.advance();
                return Node{ .kind = .{ .atom_lit = .{ .name = name } }, .loc = loc };
            },
            .true_lit => {
                self.advance();
                return Node{ .kind = .{ .bool_lit = .{ .value = true } }, .loc = loc };
            },
            .false_lit => {
                self.advance();
                return Node{ .kind = .{ .bool_lit = .{ .value = false } }, .loc = loc };
            },
            .nil_lit => {
                self.advance();
                return Node{ .kind = .{ .nil_lit = {} }, .loc = loc };
            },
            .identifier => {
                const name = self.current.lexeme;
                self.advance();
                // Check for function call: name(args)
                if (self.current.kind == .lparen) {
                    return self.parseFuncCall(name, loc);
                }
                return Node{ .kind = .{ .identifier = .{ .name = name } }, .loc = loc };
            },
            .upper_identifier => {
                const name = self.current.lexeme;
                self.advance();
                return Node{ .kind = .{ .identifier = .{ .name = name } }, .loc = loc };
            },
            .lbracket => return self.parseListLit(),
            .lbrace => return self.parseTupleLit(),
            .percent => return self.parseMapLit(),
            .lparen => {
                self.advance();
                const expr = try self.parseExpression();
                try self.expect(.rparen);
                return expr;
            },
            else => return error.UnexpectedToken,
        }
    }

    fn parseFuncCall(self: *Parser, name: []const u8, loc: Loc) ParseError!Node {
        self.advance(); // skip (
        var args: std.ArrayList(Node) = .empty;
        while (self.current.kind != .rparen and self.current.kind != .eof) {
            const arg = try self.parseExpression();
            args.append(self.allocator, arg) catch return error.OutOfMemory;
            if (self.current.kind == .comma) self.advance();
        }
        try self.expect(.rparen);
        return Node{
            .kind = .{ .func_call = .{
                .name = name,
                .args = args.toOwnedSlice(self.allocator) catch return error.OutOfMemory,
            } },
            .loc = loc,
        };
    }

    fn parseListLit(self: *Parser) ParseError!Node {
        const loc = self.currentLoc();
        self.advance(); // skip [
        var elements: std.ArrayList(Node) = .empty;
        var tail: ?*Node = null;

        while (self.current.kind != .rbracket and self.current.kind != .eof) {
            const elem = try self.parseExpression();
            elements.append(self.allocator, elem) catch return error.OutOfMemory;

            // Check for cons operator: [head | tail]
            if (self.current.kind == .pipe) {
                self.advance();
                const tail_expr = try self.parseExpression();
                const tail_ptr = self.allocator.create(Node) catch return error.OutOfMemory;
                tail_ptr.* = tail_expr;
                tail = tail_ptr;
                break;
            }
            if (self.current.kind == .comma) self.advance();
        }
        try self.expect(.rbracket);
        return Node{
            .kind = .{ .list_lit = .{
                .elements = elements.toOwnedSlice(self.allocator) catch return error.OutOfMemory,
                .tail = tail,
            } },
            .loc = loc,
        };
    }

    fn parseTupleLit(self: *Parser) ParseError!Node {
        const loc = self.currentLoc();
        self.advance(); // skip {
        var elements: std.ArrayList(Node) = .empty;
        while (self.current.kind != .rbrace and self.current.kind != .eof) {
            const elem = try self.parseExpression();
            elements.append(self.allocator, elem) catch return error.OutOfMemory;
            if (self.current.kind == .comma) self.advance();
        }
        try self.expect(.rbrace);
        return Node{
            .kind = .{ .tuple_lit = .{
                .elements = elements.toOwnedSlice(self.allocator) catch return error.OutOfMemory,
            } },
            .loc = loc,
        };
    }

    fn parseMapLit(self: *Parser) ParseError!Node {
        const loc = self.currentLoc();
        try self.expect(.percent);
        try self.expect(.lbrace);
        const entries = try self.parseKeyValueList();
        try self.expect(.rbrace);
        return Node{
            .kind = .{ .map_lit = .{ .entries = entries } },
            .loc = loc,
        };
    }

    // ============================================================
    // Helpers
    // ============================================================

    /// Parse comma-separated key: value pairs (used by become, maps).
    fn parseKeyValueList(self: *Parser) ParseError![]const Node.KeyValue {
        var fields: std.ArrayList(Node.KeyValue) = .empty;
        while (self.current.kind == .identifier) {
            const key = self.current.lexeme;
            self.advance();
            try self.expect(.colon);
            const value = try self.parseExpression();
            fields.append(self.allocator, .{ .key = key, .value = value }) catch return error.OutOfMemory;
            // Skip comma (and newlines around it for multi-line become)
            if (self.current.kind == .comma) {
                self.advance();
                self.skipNewlines();
            }
        }
        return fields.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
    }

    /// Parse comma-separated typed key-value pairs for state declarations.
    /// Supports: name: Type :: default, name: Type, name: value (untyped)
    fn parseTypedKeyValueList(self: *Parser) ParseError![]const Node.KeyValue {
        var fields: std.ArrayList(Node.KeyValue) = .empty;
        while (self.current.kind == .identifier) {
            const key = self.current.lexeme;
            self.advance();
            try self.expect(.colon);

            // Determine if this is typed (Type :: default) or untyped (value)
            // Typed if we see: UpperIdentifier, or [UpperIdentifier] (list type like [Item])
            // We peek into the lexer's source to check if [ is followed by an uppercase letter
            const is_list_type = blk: {
                if (self.current.kind != .lbracket) break :blk false;
                // Peek past [ to see if next non-space char is uppercase
                var peek_pos = self.lexer.pos;
                while (peek_pos < self.lexer.source.len and self.lexer.source[peek_pos] == ' ') {
                    peek_pos += 1;
                }
                break :blk peek_pos < self.lexer.source.len and
                    self.lexer.source[peek_pos] >= 'A' and self.lexer.source[peek_pos] <= 'Z';
            };
            if (self.current.kind == .upper_identifier or is_list_type) {
                const type_name = try self.parseTypeName();

                // Check for :: default
                if (self.current.kind == .colon_colon) {
                    self.advance();
                    const default_val = try self.parseExpression();
                    const default_ptr = self.allocator.create(Node) catch return error.OutOfMemory;
                    default_ptr.* = default_val;
                    fields.append(self.allocator, .{
                        .key = key,
                        .type_name = type_name,
                        .value = default_val,
                        .default_value = default_ptr,
                    }) catch return error.OutOfMemory;
                } else {
                    // Typed without default -- value is a placeholder nil
                    fields.append(self.allocator, .{
                        .key = key,
                        .type_name = type_name,
                        .value = Node{ .kind = .{ .nil_lit = {} }, .loc = self.currentLoc() },
                        .default_value = null,
                    }) catch return error.OutOfMemory;
                }
            } else {
                // Untyped: just key: expression (backwards compat)
                const value = try self.parseExpression();
                fields.append(self.allocator, .{ .key = key, .value = value }) catch return error.OutOfMemory;
            }

            if (self.current.kind == .comma) {
                self.advance();
                self.skipNewlines();
            }
        }
        return fields.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
    }

    /// Parse a type name: Int, String, [Item], %{K => V}
    fn parseTypeName(self: *Parser) ParseError![]const u8 {
        if (self.current.kind == .upper_identifier) {
            const name = self.current.lexeme;
            self.advance();
            return name;
        }
        if (self.current.kind == .lbracket) {
            // [Type] -- capture the whole thing as a string
            const start = self.current.lexeme.ptr;
            self.advance(); // skip [
            if (self.current.kind != .upper_identifier) return error.UnexpectedToken;
            self.advance(); // skip Type
            if (self.current.kind != .rbracket) return error.UnexpectedToken;
            const end = self.current.lexeme.ptr + self.current.lexeme.len;
            self.advance(); // skip ]
            const len = @intFromPtr(end) - @intFromPtr(start);
            return start[0..len];
        }
        return error.UnexpectedToken;
    }

    fn expect(self: *Parser, kind: Token.Kind) ParseError!void {
        if (self.current.kind != kind) {
            return error.UnexpectedToken;
        }
        self.advance();
    }

    fn advance(self: *Parser) void {
        self.current = self.lexer.next();
    }

    fn skipNewlines(self: *Parser) void {
        while (self.current.kind == .newline) {
            self.advance();
        }
    }

    fn currentLoc(self: *const Parser) Loc {
        return .{ .line = self.current.line, .col = self.current.col };
    }

    fn makeBinaryOp(self: *Parser, op: Node.BinaryOp.Op, left: Node, right: Node) ParseError!Node {
        const left_ptr = self.allocator.create(Node) catch return error.OutOfMemory;
        left_ptr.* = left;
        const right_ptr = self.allocator.create(Node) catch return error.OutOfMemory;
        right_ptr.* = right;
        return Node{
            .kind = .{ .binary_op = .{
                .op = op,
                .left = left_ptr,
                .right = right_ptr,
            } },
            .loc = left.loc,
        };
    }
};

// ============================================================
// Tests
// ============================================================

test "parse simple actor definition" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(arena.allocator(),
        \\actor Counter do
        \\  state count: 0
        \\end
    );

    const nodes = try parser.parseFile();
    try std.testing.expectEqual(@as(usize, 1), nodes.len);

    const actor = nodes[0].kind.actor_def;
    try std.testing.expectEqualStrings("Counter", actor.name);
    try std.testing.expectEqual(@as(usize, 1), actor.body.len);

    const state = actor.body[0].kind.state_def;
    try std.testing.expectEqual(@as(usize, 1), state.fields.len);
    try std.testing.expectEqualStrings("count", state.fields[0].key);
}

test "parse actor with message handler" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(arena.allocator(),
        \\actor Counter do
        \\  state count: 0
        \\  on :increment do
        \\    become count: count + 1
        \\    reply :ok
        \\  end
        \\end
    );

    const nodes = try parser.parseFile();
    const actor = nodes[0].kind.actor_def;
    try std.testing.expectEqual(@as(usize, 2), actor.body.len);

    const handler = actor.body[1].kind.message_handler;
    try std.testing.expectEqualStrings("increment", handler.name);
    try std.testing.expectEqual(@as(usize, 0), handler.params.len);
    try std.testing.expectEqual(@as(usize, 2), handler.body.len);

    // become count: count + 1
    const become = handler.body[0].kind.become_stmt;
    try std.testing.expectEqual(@as(usize, 1), become.fields.len);
    try std.testing.expectEqualStrings("count", become.fields[0].key);

    // reply :ok
    const reply = handler.body[1].kind.reply_stmt;
    try std.testing.expectEqualStrings("ok", reply.value.kind.atom_lit.name);
}

test "parse handler with parameters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(arena.allocator(),
        \\actor Cart do
        \\  on :add(item) do
        \\    reply :ok
        \\  end
        \\end
    );

    const nodes = try parser.parseFile();
    const handler = nodes[0].kind.actor_def.body[0].kind.message_handler;
    try std.testing.expectEqualStrings("add", handler.name);
    try std.testing.expectEqual(@as(usize, 1), handler.params.len);
    try std.testing.expectEqualStrings("item", handler.params[0]);
}

test "parse binary expression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(arena.allocator(), "actor A do\n  reply 1 + 2 * 3\nend");
    const nodes = try parser.parseFile();
    const reply = nodes[0].kind.actor_def.body[0].kind.reply_stmt;

    // Should parse as 1 + (2 * 3) due to precedence
    const add = reply.value.kind.binary_op;
    try std.testing.expectEqual(Node.BinaryOp.Op.add, add.op);
    try std.testing.expectEqual(@as(i64, 1), add.left.kind.integer_lit.value);

    const mul = add.right.kind.binary_op;
    try std.testing.expectEqual(Node.BinaryOp.Op.mul, mul.op);
}

test "parse list literal with cons" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(arena.allocator(), "actor A do\n  reply [1, 2 | rest]\nend");
    const nodes = try parser.parseFile();
    const reply = nodes[0].kind.actor_def.body[0].kind.reply_stmt;
    const list = reply.value.kind.list_lit;

    try std.testing.expectEqual(@as(usize, 2), list.elements.len);
    try std.testing.expect(list.tail != null);
    try std.testing.expectEqualStrings("rest", list.tail.?.kind.identifier.name);
}

test "parse tuple literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(arena.allocator(), "actor A do\n  reply {:ok, 42}\nend");
    const nodes = try parser.parseFile();
    const reply = nodes[0].kind.actor_def.body[0].kind.reply_stmt;
    const tuple = reply.value.kind.tuple_lit;

    try std.testing.expectEqual(@as(usize, 2), tuple.elements.len);
    try std.testing.expectEqualStrings("ok", tuple.elements[0].kind.atom_lit.name);
    try std.testing.expectEqual(@as(i64, 42), tuple.elements[1].kind.integer_lit.value);
}

test "parse map literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(arena.allocator(), "actor A do\n  reply %{name: \"bob\", age: 30}\nend");
    const nodes = try parser.parseFile();
    const reply = nodes[0].kind.actor_def.body[0].kind.reply_stmt;
    const map = reply.value.kind.map_lit;

    try std.testing.expectEqual(@as(usize, 2), map.entries.len);
    try std.testing.expectEqualStrings("name", map.entries[0].key);
    try std.testing.expectEqualStrings("age", map.entries[1].key);
}

test "parse function call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(arena.allocator(), "actor A do\n  reply calculate_tax(100, :us)\nend");
    const nodes = try parser.parseFile();
    const reply = nodes[0].kind.actor_def.body[0].kind.reply_stmt;
    const call = reply.value.kind.func_call;

    try std.testing.expectEqualStrings("calculate_tax", call.name);
    try std.testing.expectEqual(@as(usize, 2), call.args.len);
}

test "parse typed state with default" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(arena.allocator(),
        \\actor Counter do
        \\  state count: Int :: 0
        \\end
    );

    const nodes = try parser.parseFile();
    const state = nodes[0].kind.actor_def.body[0].kind.state_def;
    try std.testing.expectEqual(@as(usize, 1), state.fields.len);
    try std.testing.expectEqualStrings("count", state.fields[0].key);
    try std.testing.expectEqualStrings("Int", state.fields[0].type_name.?);
    try std.testing.expectEqual(@as(i64, 0), state.fields[0].value.kind.integer_lit.value);
}

test "parse typed state without default" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(arena.allocator(),
        \\actor A do
        \\  state name: String
        \\end
    );

    const nodes = try parser.parseFile();
    const state = nodes[0].kind.actor_def.body[0].kind.state_def;
    try std.testing.expectEqualStrings("name", state.fields[0].key);
    try std.testing.expectEqualStrings("String", state.fields[0].type_name.?);
    try std.testing.expect(state.fields[0].default_value == null);
}

test "parse typed state list type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(arena.allocator(),
        \\actor A do
        \\  state items: [Item] :: []
        \\end
    );

    const nodes = try parser.parseFile();
    const state = nodes[0].kind.actor_def.body[0].kind.state_def;
    try std.testing.expectEqualStrings("items", state.fields[0].key);
    try std.testing.expectEqualStrings("[Item]", state.fields[0].type_name.?);
}

test "parse multiple typed state fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(arena.allocator(),
        \\actor A do
        \\  state balance: Int :: 0, owner: String :: "unknown"
        \\end
    );

    const nodes = try parser.parseFile();
    const state = nodes[0].kind.actor_def.body[0].kind.state_def;
    try std.testing.expectEqual(@as(usize, 2), state.fields.len);
    try std.testing.expectEqualStrings("balance", state.fields[0].key);
    try std.testing.expectEqualStrings("Int", state.fields[0].type_name.?);
    try std.testing.expectEqualStrings("owner", state.fields[1].key);
    try std.testing.expectEqualStrings("String", state.fields[1].type_name.?);
}

test "parse dot access" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(arena.allocator(), "actor A do\n  reply item.price\nend");
    const nodes = try parser.parseFile();
    const reply = nodes[0].kind.actor_def.body[0].kind.reply_stmt;
    const dot = reply.value.kind.dot_access;

    try std.testing.expectEqualStrings("item", dot.object.kind.identifier.name);
    try std.testing.expectEqualStrings("price", dot.field);
}

test "parse simple pipe" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(arena.allocator(), "actor A do\n  reply items |> length(_)\nend");
    const nodes = try parser.parseFile();
    const reply = nodes[0].kind.actor_def.body[0].kind.reply_stmt;
    const pipe = reply.value.kind.pipe_expr;

    // Left side is the identifier "items"
    try std.testing.expectEqualStrings("items", pipe.left.kind.identifier.name);
    // Right side is a function call length(_)
    const call = pipe.right.kind.func_call;
    try std.testing.expectEqualStrings("length", call.name);
    try std.testing.expectEqual(@as(usize, 1), call.args.len);
    try std.testing.expectEqualStrings("_", call.args[0].kind.identifier.name);
}

test "parse chained pipes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(arena.allocator(), "actor A do\n  reply items |> filter(_, :active) |> length(_)\nend");
    const nodes = try parser.parseFile();
    const reply = nodes[0].kind.actor_def.body[0].kind.reply_stmt;

    // Chained pipes are left-associative: (items |> filter(_, :active)) |> length(_)
    const outer_pipe = reply.value.kind.pipe_expr;
    // Right of outer pipe is length(_)
    const length_call = outer_pipe.right.kind.func_call;
    try std.testing.expectEqualStrings("length", length_call.name);

    // Left of outer pipe is the inner pipe: items |> filter(_, :active)
    const inner_pipe = outer_pipe.left.kind.pipe_expr;
    try std.testing.expectEqualStrings("items", inner_pipe.left.kind.identifier.name);
    const filter_call = inner_pipe.right.kind.func_call;
    try std.testing.expectEqualStrings("filter", filter_call.name);
    try std.testing.expectEqual(@as(usize, 2), filter_call.args.len);
    try std.testing.expectEqualStrings("_", filter_call.args[0].kind.identifier.name);
    try std.testing.expectEqualStrings("active", filter_call.args[1].kind.atom_lit.name);
}

test "parse pipe into no-arg function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(arena.allocator(), "actor A do\n  reply items |> sort\nend");
    const nodes = try parser.parseFile();
    const reply = nodes[0].kind.actor_def.body[0].kind.reply_stmt;
    const pipe = reply.value.kind.pipe_expr;

    try std.testing.expectEqualStrings("items", pipe.left.kind.identifier.name);
    // Right side is just the identifier "sort" (no parens)
    try std.testing.expectEqualStrings("sort", pipe.right.kind.identifier.name);
}
