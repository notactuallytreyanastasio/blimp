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

    /// Parse a top-level construct: actor definitions, control flow, or standalone statements/expressions.
    fn parseTopLevel(self: *Parser) ParseError!Node {
        return switch (self.current.kind) {
            .kw_actor => self.parseActorDef(),
            .kw_def => self.parseDefStmt(),
            .kw_situation => self.parseSituation(),
            .kw_case => self.parseCase(),
            else => self.parseExpressionStatement(),
        };
    }

    /// Parse: actor Name do ... end
    /// Also supports dot-notation: actor Shop.Checkout do ... end
    fn parseActorDef(self: *Parser) ParseError!Node {
        const loc = self.currentLoc();
        try self.expect(.kw_actor);
        const first_name = self.current.lexeme;
        try self.expect(.upper_identifier);

        // Check for dot-notation: Shop.Checkout, App.Shop.Checkout, etc.
        var name = first_name;
        if (self.current.kind == .dot) {
            // Build the full dotted name by computing start/end pointers
            // Since the source is contiguous, we can slice from first_name start
            // to the end of the last upper_identifier lexeme
            var end_ptr = first_name.ptr + first_name.len;
            while (self.current.kind == .dot) {
                self.advance(); // skip .
                if (self.current.kind != .upper_identifier) return error.UnexpectedToken;
                end_ptr = self.current.lexeme.ptr + self.current.lexeme.len;
                self.advance();
            }
            const len = @intFromPtr(end_ptr) - @intFromPtr(first_name.ptr);
            name = first_name.ptr[0..len];
        }
        try self.expect(.kw_do);
        self.skipNewlines();

        var body: std.ArrayList(Node) = .empty;
        while (self.current.kind != .kw_end and self.current.kind != .eof) {
            const stmt = try self.parseActorBodyTopLevel();
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

    /// Parse a statement at the top level of an actor definition.
    /// Actor definitions should only contain state and on handlers at the top level.
    fn parseActorBodyTopLevel(self: *Parser) ParseError!Node {
        return switch (self.current.kind) {
            .kw_state => self.parseStateDef(),
            .kw_on => self.parseMessageHandler(),
            // Reject anything else - actor definition bodies should only have state and on
            else => error.UnexpectedToken,
        };
    }

    /// Parse a statement inside a message handler body.
    /// Message handlers can contain become, reply, situation, assignments, etc.
    fn parseHandlerBody(self: *Parser) ParseError!Node {
        return switch (self.current.kind) {
            .kw_state => error.UnexpectedToken, // state not allowed in handlers
            .kw_on => error.UnexpectedToken, // nested handlers not allowed
            .kw_become => self.parseBecomeStmt(),
            .kw_reply => self.parseReplyStmt(),
            .kw_bubble => self.parseBubbleStmt(),
            .kw_situation => self.parseSituation(),
            .kw_case => self.parseCase(),
            .identifier, .upper_identifier => {
                return self.parseExpressionStatement();
            },
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

        // Optional parameter list: (name: Type, name: Type) or (name, name) for legacy
        var params: std.ArrayList(Node.HandlerParam) = .empty;
        if (self.current.kind == .lparen) {
            self.advance();
            while (self.current.kind != .rparen and self.current.kind != .eof) {
                if (self.current.kind != .identifier) return error.UnexpectedToken;
                const param_name = self.current.lexeme;
                self.advance();

                // Check for type annotation: name: Type
                var param_type: ?[]const u8 = null;
                if (self.current.kind == .colon) {
                    self.advance();
                    param_type = try self.parseTypeName();
                }

                params.append(self.allocator, .{
                    .name = param_name,
                    .type_name = param_type,
                }) catch return error.OutOfMemory;
                if (self.current.kind == .comma) self.advance();
            }
            try self.expect(.rparen);
        }

        // Optional return type: -> Type
        // Allow newlines before each signature component for multi-line handlers
        self.skipNewlines();
        var return_type: ?[]const u8 = null;
        if (self.current.kind == .arrow) {
            self.advance();
            return_type = try self.parseTypeName();
        }

        // Optional guard: when <expression>
        self.skipNewlines();
        var guard: ?*const Node = null;
        if (self.current.kind == .kw_when) {
            self.advance();
            const guard_expr = try self.parseExpression();
            const guard_ptr = self.allocator.create(Node) catch return error.OutOfMemory;
            guard_ptr.* = guard_expr;
            guard = guard_ptr;
        }

        // Optional bubbles annotation: bubbles(ActorName)
        self.skipNewlines();
        var bubble_strategy: ?[]const u8 = null;
        if (self.current.kind == .kw_bubbles) {
            self.advance();
            try self.expect(.lparen);
            if (self.current.kind != .upper_identifier) return error.UnexpectedToken;
            bubble_strategy = self.current.lexeme;
            self.advance();
            try self.expect(.rparen);
        }

        self.skipNewlines();
        try self.expect(.kw_do);
        self.skipNewlines();

        // Parse body until end
        var body: std.ArrayList(Node) = .empty;
        while (self.current.kind != .kw_end and self.current.kind != .eof) {
            const stmt = try self.parseHandlerBody();
            body.append(self.allocator, stmt) catch return error.OutOfMemory;
            self.skipNewlines();
        }
        try self.expect(.kw_end);

        return Node{
            .kind = .{ .message_handler = .{
                .name = name,
                .params = params.toOwnedSlice(self.allocator) catch return error.OutOfMemory,
                .return_type = return_type,
                .guard = guard,
                .bubble_strategy = bubble_strategy,
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

    /// Parse: bubble or bubble reason: "msg"
    fn parseBubbleStmt(self: *Parser) ParseError!Node {
        const loc = self.currentLoc();
        try self.expect(.kw_bubble);

        // Optional reason: bubble reason: "msg"
        var reason: ?*Node = null;
        if (self.current.kind != .newline and self.current.kind != .eof and
            self.current.kind != .kw_end)
        {
            const expr = try self.parseExpression();
            const ptr = self.allocator.create(Node) catch return error.OutOfMemory;
            ptr.* = expr;
            reason = ptr;
        }

        return Node{
            .kind = .{ .bubble_stmt = .{ .reason = reason } },
            .loc = loc,
        };
    }

    /// Check if current position looks like a branch start by scanning
    /// the source for -> on the same line. Doesn't modify parser state.
    fn looksLikeBranch(self: *const Parser) bool {
        // Scan forward from AFTER current token looking for -> on this line.
        // The current token's lexeme tells us where we are in the source.
        const lexeme_ptr = @intFromPtr(self.current.lexeme.ptr);
        const source_ptr = @intFromPtr(self.lexer.source.ptr);
        if (lexeme_ptr < source_ptr) return false;
        var pos = lexeme_ptr - source_ptr + self.current.lexeme.len;
        while (pos + 1 < self.lexer.source.len) {
            const c = self.lexer.source[pos];
            if (c == '\n') return false;
            if (c == '-' and self.lexer.source[pos + 1] == '>') return true;
            pos += 1;
        }
        return false;
    }

    /// DEPRECATED: old lookahead approach
    fn peekIsBranchStart(self: *Parser) bool {
        // Save position
        const saved_pos = self.lexer.pos;
        const saved_line = self.lexer.line;
        const saved_col = self.lexer.col;
        const saved_current = self.current;

        // Try to parse an expression then check for ->
        // Simple heuristic: skip one token, check if next is ->
        const tok = self.current.kind;
        if (tok == .integer or tok == .identifier or tok == .atom or
            tok == .string or tok == .true_lit or tok == .false_lit or
            tok == .nil_lit or tok == .upper_identifier or tok == .hole or
            tok == .lbracket or tok == .percent or tok == .lbrace)
        {
            self.advance();
            // Skip optional guard: when expr
            if (self.current.kind == .kw_when) {
                // Definitely a branch start
                self.lexer.pos = saved_pos;
                self.lexer.line = saved_line;
                self.lexer.col = saved_col;
                self.current = saved_current;
                return true;
            }
            const is_arrow = self.current.kind == .arrow;
            // Restore
            self.lexer.pos = saved_pos;
            self.lexer.line = saved_line;
            self.lexer.col = saved_col;
            self.current = saved_current;
            return is_arrow;
        }
        return false;
    }

    /// Parse: situation expr do pattern -> body ... _ -> body ... end
    fn parseSituation(self: *Parser) ParseError!Node {
        const loc = self.currentLoc();
        try self.expect(.kw_situation);
        const subject = try self.parseExpression();
        const subject_ptr = self.allocator.create(Node) catch return error.OutOfMemory;
        subject_ptr.* = subject;
        try self.expect(.kw_do);
        self.skipNewlines();

        var branches: std.ArrayList(Node.Branch) = .empty;
        while (self.current.kind != .kw_end and self.current.kind != .eof) {
            const branch = try self.parseBranch();
            branches.append(self.allocator, branch) catch return error.OutOfMemory;
            self.skipNewlines();
        }
        try self.expect(.kw_end);

        return Node{
            .kind = .{ .situation = .{
                .subject = subject_ptr,
                .branches = branches.toOwnedSlice(self.allocator) catch return error.OutOfMemory,
            } },
            .loc = loc,
        };
    }

    /// Parse: case expr do pattern -> body ... end
    /// Like situation but exhaustive -- no holes allowed (semantic check, not syntactic).
    fn parseCase(self: *Parser) ParseError!Node {
        const loc = self.currentLoc();
        try self.expect(.kw_case);
        const subject = try self.parseExpression();
        const subject_ptr = self.allocator.create(Node) catch return error.OutOfMemory;
        subject_ptr.* = subject;
        try self.expect(.kw_do);
        self.skipNewlines();

        var branches: std.ArrayList(Node.Branch) = .empty;
        while (self.current.kind != .kw_end and self.current.kind != .eof) {
            const branch = try self.parseBranch();
            branches.append(self.allocator, branch) catch return error.OutOfMemory;
            self.skipNewlines();
        }
        try self.expect(.kw_end);

        return Node{
            .kind = .{ .case_expr = .{
                .subject = subject_ptr,
                .branches = branches.toOwnedSlice(self.allocator) catch return error.OutOfMemory,
            } },
            .loc = loc,
        };
    }

    /// Parse a single branch: pattern -> body or _ -> body
    fn parseBranch(self: *Parser) ParseError!Node.Branch {
        var pattern: ?*Node = null;

        if (self.current.kind == .hole) {
            // Hole branch (default/wildcard) -- pattern stays null
            self.advance();
            // If no arrow follows, this is a body-less hole directive
            // (e.g. `_ # Hole: handle this case` where comment was eaten by lexer)
            self.skipNewlines();
            if (self.current.kind != .arrow) {
                // Body-less hole: no arrow, no body - just the wildcard
                const empty_body = self.allocator.alloc(Node, 0) catch return error.OutOfMemory;
                return .{
                    .pattern = null,
                    .body = empty_body,
                };
            }
        } else {
            // Pattern expression
            const pat = try self.parseExpression();
            const pat_ptr = self.allocator.create(Node) catch return error.OutOfMemory;
            pat_ptr.* = pat;
            pattern = pat_ptr;
        }

        // Expect -> arrow
        try self.expect(.arrow);

        // Parse body statements until next branch or end
        var body: std.ArrayList(Node) = .empty;
        while (self.current.kind != .kw_end and
            self.current.kind != .eof)
        {
            // Hole at current position (not after newline) means new branch
            if (self.current.kind == .hole) break;
            // If we see a newline, check if the next line starts a new branch
            if (self.current.kind == .newline) {
                self.skipNewlines();
                if (self.current.kind == .kw_end or self.current.kind == .eof) break;
                if (self.current.kind == .hole or self.current.kind == .atom) break;
                // For other tokens (integer, identifier, true, etc.), peek ahead
                // to see if there's a -> following. If so, it's a new branch.
                if (self.looksLikeBranch()) break;
                continue;
            }
            const stmt = try self.parseHandlerBody();
            body.append(self.allocator, stmt) catch return error.OutOfMemory;
        }

        return .{
            .pattern = pattern,
            .body = body.toOwnedSlice(self.allocator) catch return error.OutOfMemory,
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

    /// Public wrapper for file parsing (used by REPL multi-line input).
    pub fn parseFilePublic(self: *Parser) ParseError![]const Node {
        return self.parseFile();
    }

    /// Public wrapper for expression parsing (used by REPL and evaluator).
    pub fn parseExpressionPublic(self: *Parser) ParseError!Node {
        return self.parseExpression();
    }

    /// Public wrapper for statement parsing (used by REPL).
    /// Tries to parse an assignment (identifier = expr), falls back to expression.
    /// Also handles situation/case as top-level statements.
    pub fn parseStatementPublic(self: *Parser) ParseError!Node {
        self.skipNewlines();
        return self.parseTopLevel();
    }

    // ============================================================
    // Expression parsing (Pratt / precedence climbing)
    // ============================================================

    fn parseExpression(self: *Parser) ParseError!Node {
        return self.parseOrElse();
    }

    /// Parse: expr orelse fallback_expr
    /// Lowest precedence infix operator.
    fn parseOrElse(self: *Parser) ParseError!Node {
        var left = try self.parsePipe();
        if (self.current.kind == .kw_orelse) {
            self.advance();
            const right = try self.parsePipe();
            const left_ptr = self.allocator.create(Node) catch return error.OutOfMemory;
            left_ptr.* = left;
            const right_ptr = self.allocator.create(Node) catch return error.OutOfMemory;
            right_ptr.* = right;
            left = Node{
                .kind = .{ .orelse_expr = .{
                    .try_expr = left_ptr,
                    .fallback = right_ptr,
                } },
                .loc = left.loc,
            };
        }
        return left;
    }

    /// Parse pipe expressions: left-associative, lowest precedence among binary ops.
    /// a |> b(_, x) |> c(_) parses as (a |> b(_, x)) |> c(_)
    fn parsePipe(self: *Parser) ParseError!Node {
        var left = try self.parseSendExpr();
        while (self.current.kind == .pipe_arrow) {
            self.advance();
            const right = try self.parseSendExpr();
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

    /// Parse: expr <- :message(args)
    /// Second-lowest precedence. Left side is a normal expression, right side is atom + optional args.
    fn parseSendExpr(self: *Parser) ParseError!Node {
        var left = try self.parseBinaryOr();
        if (self.current.kind == .send_arrow) {
            self.advance();
            // Expect atom for message name
            if (self.current.kind != .atom) return error.UnexpectedToken;
            const raw_name = self.current.lexeme;
            const name = if (raw_name.len > 0 and raw_name[0] == ':') raw_name[1..] else raw_name;
            self.advance();

            // Optional argument list
            var args: std.ArrayList(Node) = .empty;
            if (self.current.kind == .lparen) {
                self.advance();
                while (self.current.kind != .rparen and self.current.kind != .eof) {
                    const arg = try self.parseExpression();
                    args.append(self.allocator, arg) catch return error.OutOfMemory;
                    if (self.current.kind == .comma) self.advance();
                }
                try self.expect(.rparen);
            }

            const left_ptr = self.allocator.create(Node) catch return error.OutOfMemory;
            left_ptr.* = left;
            left = Node{
                .kind = .{ .message_send = .{
                    .target = left_ptr,
                    .message = name,
                    .args = args.toOwnedSlice(self.allocator) catch return error.OutOfMemory,
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
        while (self.current.kind == .plus or self.current.kind == .minus or self.current.kind == .plus_plus) {
            const op: Node.BinaryOp.Op = if (self.current.kind == .plus_plus) .concat else if (self.current.kind == .plus) .add else .sub;
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
            .hole => {
                self.advance();
                return Node{ .kind = .{ .hole = .{ .directive = null } }, .loc = loc };
            },
            .kw_spawn => return self.parseSpawnExpr(),
            .kw_fn => return self.parseFnExpr(),
            .kw_try => return self.parseTryCatch(),
            .kw_for => return self.parseForExpr(),
            .kw_self => {
                self.advance();
                return Node{ .kind = .{ .self_ref = {} }, .loc = loc };
            },
            .dot_dot_dot => return self.parseSpread(.spread_map),
            .dot_dot => return self.parseSpread(.spread_each),
            .lbracket => return self.parseListLit(),
            .lbrace => return self.parseTupleLit(),
            .percent => return self.parsePercentExpr(),
            .lparen => {
                self.advance();
                const expr = try self.parseExpression();
                try self.expect(.rparen);
                return expr;
            },
            else => return error.UnexpectedToken,
        }
    }

    /// Parse: spawn ActorName, spawn(ActorName), spawn ActorName, k: v, or spawn(ActorName, k: v)
    fn parseSpawnExpr(self: *Parser) ParseError!Node {
        const loc = self.currentLoc();
        try self.expect(.kw_spawn);

        // Allow optional parens: spawn(Counter) or spawn Counter
        const has_parens = self.current.kind == .lparen;
        if (has_parens) self.advance();

        // Expect an upper_identifier for the actor name, with optional dot notation
        if (self.current.kind != .upper_identifier) return error.UnexpectedToken;
        var actor_name = self.current.lexeme;
        self.advance();

        // Handle dot notation: spawn Shop.Checkout
        while (self.current.kind == .dot) {
            self.advance();
            if (self.current.kind != .upper_identifier) return error.UnexpectedToken;
            actor_name = std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ actor_name, self.current.lexeme }) catch return error.OutOfMemory;
            self.advance();
        }

        // Optional state overrides: , key: value, key: value
        var overrides: []const Node.KeyValue = &.{};
        if (self.current.kind == .comma) {
            self.advance();
            overrides = try self.parseKeyValueList();
        }

        if (has_parens) {
            if (self.current.kind != .rparen) return error.UnexpectedToken;
            self.advance();
        }

        return Node{
            .kind = .{ .spawn_expr = .{
                .actor_name = actor_name,
                .overrides = overrides,
            } },
            .loc = loc,
        };
    }

    /// Parse: fn(x, y) do ... end
    /// Parse: for x in list do ... end
    fn parseForExpr(self: *Parser) ParseError!Node {
        const loc = self.currentLoc();
        try self.expect(.kw_for);

        if (self.current.kind != .identifier) return error.UnexpectedToken;
        const var_name = self.current.lexeme;
        self.advance();

        try self.expect(.kw_in);
        const iterable = try self.parseExpression();
        const iter_ptr = self.allocator.create(Node) catch return error.OutOfMemory;
        iter_ptr.* = iterable;

        self.skipNewlines();
        try self.expect(.kw_do);
        self.skipNewlines();

        var body: std.ArrayList(Node) = .empty;
        while (self.current.kind != .kw_end and self.current.kind != .eof) {
            const stmt = try self.parseTopLevel();
            body.append(self.allocator, stmt) catch return error.OutOfMemory;
            self.skipNewlines();
        }
        try self.expect(.kw_end);

        return Node{
            .kind = .{ .for_expr = .{
                .var_name = var_name,
                .iterable = iter_ptr,
                .body = body.toOwnedSlice(self.allocator) catch return error.OutOfMemory,
            } },
            .loc = loc,
        };
    }

    /// Parse: ...list, fn  or  ..list, fn
    fn parseSpread(self: *Parser, comptime kind: std.meta.Tag(Node.Kind)) ParseError!Node {
        const loc = self.currentLoc();
        self.advance(); // skip .. or ...

        const iterable = try self.parseExpression();
        const iter_ptr = self.allocator.create(Node) catch return error.OutOfMemory;
        iter_ptr.* = iterable;

        try self.expect(.comma);

        const func = try self.parseExpression();
        const func_ptr = self.allocator.create(Node) catch return error.OutOfMemory;
        func_ptr.* = func;

        return Node{
            .kind = @unionInit(Node.Kind, @tagName(kind), .{
                .iterable = iter_ptr,
                .func = func_ptr,
            }),
            .loc = loc,
        };
    }

    /// Parse: try do ... catch var do ... end
    fn parseTryCatch(self: *Parser) ParseError!Node {
        const loc = self.currentLoc();
        try self.expect(.kw_try);
        self.skipNewlines();
        try self.expect(.kw_do);
        self.skipNewlines();

        // Try body
        var try_body: std.ArrayList(Node) = .empty;
        while (self.current.kind != .kw_catch and self.current.kind != .kw_end and self.current.kind != .eof) {
            const stmt = try self.parseTopLevel();
            try_body.append(self.allocator, stmt) catch return error.OutOfMemory;
            self.skipNewlines();
        }

        // Catch clause
        var catch_var: ?[]const u8 = null;
        var catch_body: std.ArrayList(Node) = .empty;

        if (self.current.kind == .kw_catch) {
            self.advance();
            self.skipNewlines();

            // Optional catch variable
            if (self.current.kind == .identifier) {
                catch_var = self.current.lexeme;
                self.advance();
            }

            self.skipNewlines();
            try self.expect(.kw_do);
            self.skipNewlines();

            while (self.current.kind != .kw_end and self.current.kind != .eof) {
                const stmt = try self.parseTopLevel();
                catch_body.append(self.allocator, stmt) catch return error.OutOfMemory;
                self.skipNewlines();
            }
        }

        try self.expect(.kw_end);

        return Node{
            .kind = .{ .try_catch = .{
                .try_body = try_body.toOwnedSlice(self.allocator) catch return error.OutOfMemory,
                .catch_var = catch_var,
                .catch_body = catch_body.toOwnedSlice(self.allocator) catch return error.OutOfMemory,
            } },
            .loc = loc,
        };
    }

    /// Parse: def name(params) do ... end
    /// Parse typed parameter list: (name: Type, name: Type) or (name, name) for untyped
    fn parseTypedParamList(self: *Parser) ParseError![]const Node.HandlerParam {
        try self.expect(.lparen);
        var params: std.ArrayList(Node.HandlerParam) = .empty;
        while (self.current.kind != .rparen and self.current.kind != .eof) {
            if (self.current.kind != .identifier) return error.UnexpectedToken;
            const param_name = self.current.lexeme;
            self.advance();

            // Optional type annotation: name: Type
            var type_name: ?[]const u8 = null;
            if (self.current.kind == .colon) {
                self.advance();
                // Parse type name (simple or complex)
                if (self.current.kind == .upper_identifier) {
                    type_name = self.current.lexeme;
                    self.advance();
                } else if (self.current.kind == .lbracket) {
                    // [Type]
                    self.advance();
                    if (self.current.kind == .upper_identifier) {
                        type_name = std.fmt.allocPrint(self.allocator, "[{s}]", .{self.current.lexeme}) catch return error.OutOfMemory;
                        self.advance();
                    }
                    try self.expect(.rbracket);
                }
            }

            params.append(self.allocator, .{
                .name = param_name,
                .type_name = type_name,
            }) catch return error.OutOfMemory;

            if (self.current.kind == .comma) self.advance();
        }
        try self.expect(.rparen);
        return params.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
    }

    fn parseDefStmt(self: *Parser) ParseError!Node {
        const loc = self.currentLoc();
        try self.expect(.kw_def);

        if (self.current.kind != .identifier) return error.UnexpectedToken;
        const name = self.current.lexeme;
        self.advance();

        // Typed parameter list
        const params = try self.parseTypedParamList();

        // Optional return type: -> Type
        var return_type: ?[]const u8 = null;
        if (self.current.kind == .arrow) {
            self.advance();
            if (self.current.kind == .upper_identifier) {
                return_type = self.current.lexeme;
                self.advance();
            }
        }

        self.skipNewlines();
        try self.expect(.kw_do);
        self.skipNewlines();

        var body: std.ArrayList(Node) = .empty;
        while (self.current.kind != .kw_end and self.current.kind != .eof) {
            const stmt = try self.parseTopLevel();
            body.append(self.allocator, stmt) catch return error.OutOfMemory;
            self.skipNewlines();
        }
        try self.expect(.kw_end);

        return Node{
            .kind = .{ .def_stmt = .{
                .name = name,
                .params = params,
                .return_type = return_type,
                .body = body.toOwnedSlice(self.allocator) catch return error.OutOfMemory,
            } },
            .loc = loc,
        };
    }

    fn parseFnExpr(self: *Parser) ParseError!Node {
        const loc = self.currentLoc();
        try self.expect(.kw_fn);

        // Typed parameter list
        const params = try self.parseTypedParamList();

        // Optional return type: -> Type
        var return_type: ?[]const u8 = null;
        if (self.current.kind == .arrow) {
            self.advance();
            if (self.current.kind == .upper_identifier) {
                return_type = self.current.lexeme;
                self.advance();
            }
        }

        // Body: do ... end
        self.skipNewlines();
        try self.expect(.kw_do);
        self.skipNewlines();

        var body: std.ArrayList(Node) = .empty;
        while (self.current.kind != .kw_end and self.current.kind != .eof) {
            const stmt = try self.parseTopLevel();
            body.append(self.allocator, stmt) catch return error.OutOfMemory;
            self.skipNewlines();
        }
        try self.expect(.kw_end);

        return Node{
            .kind = .{ .fn_expr = .{
                .params = params,
                .return_type = return_type,
                .body = body.toOwnedSlice(self.allocator) catch return error.OutOfMemory,
            } },
            .loc = loc,
        };
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
        self.skipNewlines();
        var elements: std.ArrayList(Node) = .empty;
        var tail: ?*Node = null;

        while (self.current.kind != .rbracket and self.current.kind != .eof) {
            self.skipNewlines();
            if (self.current.kind == .rbracket) break;
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
            self.skipNewlines();
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
        self.skipNewlines();
        var elements: std.ArrayList(Node) = .empty;
        while (self.current.kind != .rbrace and self.current.kind != .eof) {
            self.skipNewlines();
            if (self.current.kind == .rbrace) break;
            const elem = try self.parseExpression();
            elements.append(self.allocator, elem) catch return error.OutOfMemory;
            if (self.current.kind == .comma) self.advance();
            self.skipNewlines();
        }
        try self.expect(.rbrace);
        return Node{
            .kind = .{ .tuple_lit = .{
                .elements = elements.toOwnedSlice(self.allocator) catch return error.OutOfMemory,
            } },
            .loc = loc,
        };
    }

    /// Dispatch %{ for maps or %Name{ for structs
    fn parsePercentExpr(self: *Parser) ParseError!Node {
        const loc = self.currentLoc();
        try self.expect(.percent);

        // %Name{...} = struct literal
        if (self.current.kind == .upper_identifier) {
            return self.parseStructLit(loc);
        }

        // %{...} = map literal
        return self.parseMapLitBody(loc);
    }

    fn parseStructLit(self: *Parser, loc: ast.Loc) ParseError!Node {
        const type_name = self.current.lexeme;
        self.advance();

        // Handle dot notation: %Shop.Checkout{...}
        var name = type_name;
        while (self.current.kind == .dot) {
            self.advance();
            if (self.current.kind != .upper_identifier) return error.UnexpectedToken;
            name = std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ name, self.current.lexeme }) catch return error.OutOfMemory;
            self.advance();
        }

        try self.expect(.lbrace);
        self.skipNewlines();
        var fields: std.ArrayList(ast.Node.KeyValue) = .empty;
        while (self.current.kind != .rbrace and self.current.kind != .eof) {
            if (self.current.kind != .identifier) return error.UnexpectedToken;
            const key = self.current.lexeme;
            self.advance();
            try self.expect(.colon);
            self.skipNewlines();
            const value = try self.parseExpression();
            fields.append(self.allocator, .{ .key = key, .value = value }) catch return error.OutOfMemory;
            if (self.current.kind == .comma) self.advance();
            self.skipNewlines();
        }
        try self.expect(.rbrace);

        return .{
            .kind = .{ .struct_lit = .{
                .type_name = name,
                .fields = fields.toOwnedSlice(self.allocator) catch return error.OutOfMemory,
            } },
            .loc = loc,
        };
    }

    fn parseMapLitBody(self: *Parser, loc: ast.Loc) ParseError!Node {
        // Already consumed %, now expect {
        try self.expect(.lbrace);
        var entries: std.ArrayList(ast.Node.KeyValue) = .empty;
        while (self.current.kind != .rbrace and self.current.kind != .eof) {
            if (self.current.kind != .identifier and self.current.kind != .string) return error.UnexpectedToken;
            const key = self.current.lexeme;
            self.advance();
            try self.expect(.colon);
            self.skipNewlines();
            const value = try self.parseExpression();
            entries.append(self.allocator, .{ .key = key, .value = value }) catch return error.OutOfMemory;
            if (self.current.kind == .comma) self.advance();
            self.skipNewlines();
        }
        try self.expect(.rbrace);
        return .{
            .kind = .{ .map_lit = .{ .entries = entries.toOwnedSlice(self.allocator) catch return error.OutOfMemory } },
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
            const is_tuple_type = self.current.kind == .lbrace;
            const is_map_type = self.current.kind == .percent;
            if (self.current.kind == .upper_identifier or is_list_type or is_tuple_type or is_map_type) {
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

    /// Parse a type name: Int, String, [Item], {A, B}, %{K => V}
    /// Captures the full source span as a string for the checker to parse.
    fn parseTypeName(self: *Parser) ParseError![]const u8 {
        if (self.current.kind == .upper_identifier) {
            const name = self.current.lexeme;
            self.advance();
            return name;
        }
        if (self.current.kind == .lbracket) {
            // [Type] -- list type
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
        if (self.current.kind == .lbrace) {
            // {A, B, C} -- tuple type
            const start = self.current.lexeme.ptr;
            self.advance(); // skip {
            // Consume types separated by commas until }
            while (self.current.kind != .rbrace and self.current.kind != .eof) {
                if (self.current.kind == .upper_identifier) {
                    self.advance();
                } else if (self.current.kind == .lbracket) {
                    // Nested list type inside tuple: {[Item], Int}
                    self.advance(); // [
                    if (self.current.kind == .upper_identifier) self.advance();
                    if (self.current.kind == .rbracket) self.advance();
                } else {
                    return error.UnexpectedToken;
                }
                if (self.current.kind == .comma) self.advance();
            }
            if (self.current.kind != .rbrace) return error.UnexpectedToken;
            const end = self.current.lexeme.ptr + self.current.lexeme.len;
            self.advance(); // skip }
            const len = @intFromPtr(end) - @intFromPtr(start);
            return start[0..len];
        }
        if (self.current.kind == .percent) {
            // %{K => V} -- map type
            const start = self.current.lexeme.ptr;
            self.advance(); // skip %
            if (self.current.kind != .lbrace) return error.UnexpectedToken;
            self.advance(); // skip {
            // Key type
            if (self.current.kind != .upper_identifier) return error.UnexpectedToken;
            self.advance();
            // => separator
            if (self.current.kind != .eq) return error.UnexpectedToken;
            self.advance();
            if (self.current.kind != .gt) return error.UnexpectedToken;
            self.advance();
            // Value type
            if (self.current.kind != .upper_identifier) return error.UnexpectedToken;
            self.advance();
            if (self.current.kind != .rbrace) return error.UnexpectedToken;
            const end = self.current.lexeme.ptr + self.current.lexeme.len;
            self.advance(); // skip }
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

test "parse handler with typed parameters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(arena.allocator(),
        \\actor Cart do
        \\  on :add(item: Item) do
        \\    reply :ok
        \\  end
        \\end
    );

    const nodes = try parser.parseFile();
    const handler = nodes[0].kind.actor_def.body[0].kind.message_handler;
    try std.testing.expectEqualStrings("add", handler.name);
    try std.testing.expectEqual(@as(usize, 1), handler.params.len);
    try std.testing.expectEqualStrings("item", handler.params[0].name);
    try std.testing.expectEqualStrings("Item", handler.params[0].type_name.?);
}

test "parse handler with untyped parameters (legacy)" {
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
    try std.testing.expectEqualStrings("item", handler.params[0].name);
    try std.testing.expect(handler.params[0].type_name == null);
}

test "parse handler with return type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(arena.allocator(),
        \\actor Cart do
        \\  on :total -> Int do
        \\    reply 42
        \\  end
        \\end
    );

    const nodes = try parser.parseFile();
    const handler = nodes[0].kind.actor_def.body[0].kind.message_handler;
    try std.testing.expectEqualStrings("total", handler.name);
    try std.testing.expectEqualStrings("Int", handler.return_type.?);
}

test "parse handler with typed params and return type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(arena.allocator(),
        \\actor Checkout do
        \\  on :charge(payment: Payment) -> Receipt do
        \\    reply :ok
        \\  end
        \\end
    );

    const nodes = try parser.parseFile();
    const handler = nodes[0].kind.actor_def.body[0].kind.message_handler;
    try std.testing.expectEqualStrings("charge", handler.name);
    try std.testing.expectEqual(@as(usize, 1), handler.params.len);
    try std.testing.expectEqualStrings("payment", handler.params[0].name);
    try std.testing.expectEqualStrings("Payment", handler.params[0].type_name.?);
    try std.testing.expectEqualStrings("Receipt", handler.return_type.?);
}

test "parse binary expression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(arena.allocator(), "actor A do\n  on :test do\n    reply 1 + 2 * 3\n  end\nend");
    const nodes = try parser.parseFile();
    const handler = nodes[0].kind.actor_def.body[0].kind.message_handler;
    const reply = handler.body[0].kind.reply_stmt;

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

    var parser = Parser.init(arena.allocator(), "actor A do\n  on :test do\n    reply [1, 2 | rest]\n  end\nend");
    const nodes = try parser.parseFile();
    const handler = nodes[0].kind.actor_def.body[0].kind.message_handler;
    const reply = handler.body[0].kind.reply_stmt;
    const list = reply.value.kind.list_lit;

    try std.testing.expectEqual(@as(usize, 2), list.elements.len);
    try std.testing.expect(list.tail != null);
    try std.testing.expectEqualStrings("rest", list.tail.?.kind.identifier.name);
}

test "parse tuple literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(arena.allocator(), "actor A do\n  on :test do\n    reply {:ok, 42}\n  end\nend");
    const nodes = try parser.parseFile();
    const handler = nodes[0].kind.actor_def.body[0].kind.message_handler;
    const reply = handler.body[0].kind.reply_stmt;
    const tuple = reply.value.kind.tuple_lit;

    try std.testing.expectEqual(@as(usize, 2), tuple.elements.len);
    try std.testing.expectEqualStrings("ok", tuple.elements[0].kind.atom_lit.name);
    try std.testing.expectEqual(@as(i64, 42), tuple.elements[1].kind.integer_lit.value);
}

test "parse map literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(arena.allocator(), "actor A do\n  on :test do\n    reply %{name: \"bob\", age: 30}\n  end\nend");
    const nodes = try parser.parseFile();
    const handler = nodes[0].kind.actor_def.body[0].kind.message_handler;
    const reply = handler.body[0].kind.reply_stmt;
    const map = reply.value.kind.map_lit;

    try std.testing.expectEqual(@as(usize, 2), map.entries.len);
    try std.testing.expectEqualStrings("name", map.entries[0].key);
    try std.testing.expectEqualStrings("age", map.entries[1].key);
}

test "parse function call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(arena.allocator(), "actor A do\n  on :test do\n    reply calculate_tax(100, :us)\n  end\nend");
    const nodes = try parser.parseFile();
    const handler = nodes[0].kind.actor_def.body[0].kind.message_handler;
    const reply = handler.body[0].kind.reply_stmt;
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

    var parser = Parser.init(arena.allocator(), "actor A do\n  on :test do\n    reply item.price\n  end\nend");
    const nodes = try parser.parseFile();
    const handler = nodes[0].kind.actor_def.body[0].kind.message_handler;
    const reply = handler.body[0].kind.reply_stmt;
    const dot = reply.value.kind.dot_access;

    try std.testing.expectEqualStrings("item", dot.object.kind.identifier.name);
    try std.testing.expectEqualStrings("price", dot.field);
}

test "parse simple pipe" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(arena.allocator(), "actor A do\n  on :test do\n    reply items |> length(_)\n  end\nend");
    const nodes = try parser.parseFile();
    const handler = nodes[0].kind.actor_def.body[0].kind.message_handler;
    const reply = handler.body[0].kind.reply_stmt;
    const pipe = reply.value.kind.pipe_expr;

    // Left side is the identifier "items"
    try std.testing.expectEqualStrings("items", pipe.left.kind.identifier.name);
    // Right side is a function call length(_)
    const call = pipe.right.kind.func_call;
    try std.testing.expectEqualStrings("length", call.name);
    try std.testing.expectEqual(@as(usize, 1), call.args.len);
    // _ is lexed as a hole token, so it parses as a hole node
    try std.testing.expect(call.args[0].kind == .hole);
}

test "parse chained pipes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(arena.allocator(), "actor A do\n  on :test do\n    reply items |> filter(_, :active) |> length(_)\n  end\nend");
    const nodes = try parser.parseFile();
    const handler = nodes[0].kind.actor_def.body[0].kind.message_handler;
    const reply = handler.body[0].kind.reply_stmt;

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
    // _ is lexed as a hole token, so it parses as a hole node
    try std.testing.expect(filter_call.args[0].kind == .hole);
    try std.testing.expectEqualStrings("active", filter_call.args[1].kind.atom_lit.name);
}

test "parse pipe into no-arg function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(arena.allocator(), "actor A do\n  on :test do\n    reply items |> sort\n  end\nend");
    const nodes = try parser.parseFile();
    const handler = nodes[0].kind.actor_def.body[0].kind.message_handler;
    const reply = handler.body[0].kind.reply_stmt;
    const pipe = reply.value.kind.pipe_expr;

    try std.testing.expectEqualStrings("items", pipe.left.kind.identifier.name);
    // Right side is just the identifier "sort" (no parens)
    try std.testing.expectEqualStrings("sort", pipe.right.kind.identifier.name);
}

test "parse hole as expression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(arena.allocator(), "actor A do\n  on :test do\n    reply _\n  end\nend");
    const nodes = try parser.parseFile();
    const handler = nodes[0].kind.actor_def.body[0].kind.message_handler;
    const reply = handler.body[0].kind.reply_stmt;
    // The hole should be parsed as a hole node
    const h = reply.value.kind.hole;
    try std.testing.expect(h.directive == null);
}

test "parse situation with branches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(arena.allocator(),
        \\actor A do
        \\  on :msg do
        \\    situation x do
        \\      :a -> reply 1
        \\      :b -> reply 2
        \\    end
        \\  end
        \\end
    );
    const nodes = try parser.parseFile();
    const handler = nodes[0].kind.actor_def.body[0].kind.message_handler;
    const sit = handler.body[0].kind.situation;

    // Subject should be identifier "x"
    try std.testing.expectEqualStrings("x", sit.subject.kind.identifier.name);

    // Two branches
    try std.testing.expectEqual(@as(usize, 2), sit.branches.len);

    // First branch: pattern is :a, body is reply 1
    const b0 = sit.branches[0];
    try std.testing.expectEqualStrings("a", b0.pattern.?.kind.atom_lit.name);
    try std.testing.expectEqual(@as(usize, 1), b0.body.len);
    try std.testing.expectEqual(@as(i64, 1), b0.body[0].kind.reply_stmt.value.kind.integer_lit.value);

    // Second branch: pattern is :b, body is reply 2
    const b1 = sit.branches[1];
    try std.testing.expectEqualStrings("b", b1.pattern.?.kind.atom_lit.name);
    try std.testing.expectEqual(@as(usize, 1), b1.body.len);
    try std.testing.expectEqual(@as(i64, 2), b1.body[0].kind.reply_stmt.value.kind.integer_lit.value);
}

test "parse situation with hole branch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(arena.allocator(),
        \\actor A do
        \\  on :msg do
        \\    situation x do
        \\      :a -> reply 1
        \\      _ -> reply 0
        \\    end
        \\  end
        \\end
    );
    const nodes = try parser.parseFile();
    const handler = nodes[0].kind.actor_def.body[0].kind.message_handler;
    const sit = handler.body[0].kind.situation;

    try std.testing.expectEqual(@as(usize, 2), sit.branches.len);

    // First branch: :a -> reply 1
    const b0 = sit.branches[0];
    try std.testing.expect(b0.pattern != null);
    try std.testing.expectEqualStrings("a", b0.pattern.?.kind.atom_lit.name);

    // Second branch: _ -> reply 0 (hole/default branch, pattern is null)
    const b1 = sit.branches[1];
    try std.testing.expect(b1.pattern == null);
    try std.testing.expectEqual(@as(usize, 1), b1.body.len);
    try std.testing.expectEqual(@as(i64, 0), b1.body[0].kind.reply_stmt.value.kind.integer_lit.value);
}

test "parse message send" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(arena.allocator(),
        \\actor A do
        \\  on :test do
        \\    checkout <- :add(item)
        \\  end
        \\end
    );
    const nodes = try parser.parseFile();
    const handler = nodes[0].kind.actor_def.body[0].kind.message_handler;
    const body = handler.body;
    try std.testing.expectEqual(@as(usize, 1), body.len);

    const send = body[0].kind.message_send;
    try std.testing.expectEqualStrings("checkout", send.target.kind.identifier.name);
    try std.testing.expectEqualStrings("add", send.message);
    try std.testing.expectEqual(@as(usize, 1), send.args.len);
    try std.testing.expectEqualStrings("item", send.args[0].kind.identifier.name);
}

test "parse message send no args" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(arena.allocator(),
        \\actor A do
        \\  on :test do
        \\    counter <- :increment
        \\  end
        \\end
    );
    const nodes = try parser.parseFile();
    const handler = nodes[0].kind.actor_def.body[0].kind.message_handler;
    const body = handler.body;
    try std.testing.expectEqual(@as(usize, 1), body.len);

    const send = body[0].kind.message_send;
    try std.testing.expectEqualStrings("counter", send.target.kind.identifier.name);
    try std.testing.expectEqualStrings("increment", send.message);
    try std.testing.expectEqual(@as(usize, 0), send.args.len);
}

test "parse message send with orelse" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(arena.allocator(),
        \\actor A do
        \\  on :test do
        \\    result = checkout <- :charge(payment) orelse :error
        \\  end
        \\end
    );
    const nodes = try parser.parseFile();
    const handler = nodes[0].kind.actor_def.body[0].kind.message_handler;
    const body = handler.body;
    try std.testing.expectEqual(@as(usize, 1), body.len);

    // result = (orelse (send checkout :charge(payment)) :error)
    const assign = body[0].kind.assign_stmt;
    try std.testing.expectEqualStrings("result", assign.name);

    const orelse_node = assign.value.kind.orelse_expr;
    const send = orelse_node.try_expr.kind.message_send;
    try std.testing.expectEqualStrings("checkout", send.target.kind.identifier.name);
    try std.testing.expectEqualStrings("charge", send.message);
    try std.testing.expectEqual(@as(usize, 1), send.args.len);

    try std.testing.expectEqualStrings("error", orelse_node.fallback.kind.atom_lit.name);
}

test "parse orelse with expression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(arena.allocator(),
        \\actor A do
        \\  on :test do
        \\    reply x orelse 0
        \\  end
        \\end
    );
    const nodes = try parser.parseFile();
    const handler = nodes[0].kind.actor_def.body[0].kind.message_handler;
    const reply = handler.body[0].kind.reply_stmt;
    const orelse_node = reply.value.kind.orelse_expr;

    try std.testing.expectEqualStrings("x", orelse_node.try_expr.kind.identifier.name);
    try std.testing.expectEqual(@as(i64, 0), orelse_node.fallback.kind.integer_lit.value);
}

test "parse handler with guard" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(arena.allocator(),
        \\actor Account do
        \\  on :withdraw(amount: Int) when amount > 0 do
        \\    reply :ok
        \\  end
        \\end
    );

    const nodes = try parser.parseFile();
    const handler = nodes[0].kind.actor_def.body[0].kind.message_handler;
    try std.testing.expectEqualStrings("withdraw", handler.name);
    try std.testing.expectEqual(@as(usize, 1), handler.params.len);
    try std.testing.expectEqualStrings("amount", handler.params[0].name);
    try std.testing.expectEqualStrings("Int", handler.params[0].type_name.?);

    // Guard should be: amount > 0
    try std.testing.expect(handler.guard != null);
    const guard = handler.guard.?;
    const bin_op = guard.kind.binary_op;
    try std.testing.expectEqual(Node.BinaryOp.Op.gt, bin_op.op);
    try std.testing.expectEqualStrings("amount", bin_op.left.kind.identifier.name);
    try std.testing.expectEqual(@as(i64, 0), bin_op.right.kind.integer_lit.value);

    // No bubbles
    try std.testing.expect(handler.bubble_strategy == null);
}

test "parse handler with bubbles" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(arena.allocator(),
        \\actor Payment do
        \\  on :charge(payment: Payment) bubbles(CascadeBubble) do
        \\    reply :ok
        \\  end
        \\end
    );

    const nodes = try parser.parseFile();
    const handler = nodes[0].kind.actor_def.body[0].kind.message_handler;
    try std.testing.expectEqualStrings("charge", handler.name);
    try std.testing.expectEqual(@as(usize, 1), handler.params.len);

    // No guard
    try std.testing.expect(handler.guard == null);

    // Bubbles should be present
    try std.testing.expect(handler.bubble_strategy != null);
    try std.testing.expectEqualStrings("CascadeBubble", handler.bubble_strategy.?);
}

test "parse handler with guard and bubbles" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(arena.allocator(),
        \\actor Payment do
        \\  on :charge(payment: Payment) when valid?(payment) bubbles(CascadeBubble) do
        \\    reply :ok
        \\  end
        \\end
    );

    const nodes = try parser.parseFile();
    const handler = nodes[0].kind.actor_def.body[0].kind.message_handler;
    try std.testing.expectEqualStrings("charge", handler.name);

    // Guard should be: valid?(payment)
    try std.testing.expect(handler.guard != null);
    const guard = handler.guard.?;
    const call = guard.kind.func_call;
    try std.testing.expectEqualStrings("valid?", call.name);
    try std.testing.expectEqual(@as(usize, 1), call.args.len);

    // Bubbles should be present
    try std.testing.expect(handler.bubble_strategy != null);
    try std.testing.expectEqualStrings("CascadeBubble", handler.bubble_strategy.?);
}

test "parse case with branches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(arena.allocator(),
        \\actor A do
        \\  on :msg do
        \\    case x do
        \\      :a -> reply 1
        \\      :b -> reply 2
        \\    end
        \\  end
        \\end
    );
    const nodes = try parser.parseFile();
    const handler = nodes[0].kind.actor_def.body[0].kind.message_handler;
    const case_node = handler.body[0].kind.case_expr;

    // Subject should be identifier "x"
    try std.testing.expectEqualStrings("x", case_node.subject.kind.identifier.name);

    // Two branches
    try std.testing.expectEqual(@as(usize, 2), case_node.branches.len);

    // First branch: pattern is :a, body is reply 1
    const b0 = case_node.branches[0];
    try std.testing.expectEqualStrings("a", b0.pattern.?.kind.atom_lit.name);
    try std.testing.expectEqual(@as(usize, 1), b0.body.len);
    try std.testing.expectEqual(@as(i64, 1), b0.body[0].kind.reply_stmt.value.kind.integer_lit.value);

    // Second branch: pattern is :b, body is reply 2
    const b1 = case_node.branches[1];
    try std.testing.expectEqualStrings("b", b1.pattern.?.kind.atom_lit.name);
    try std.testing.expectEqual(@as(usize, 1), b1.body.len);
    try std.testing.expectEqual(@as(i64, 2), b1.body[0].kind.reply_stmt.value.kind.integer_lit.value);
}

test "parse case with expression subject" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(arena.allocator(),
        \\actor A do
        \\  on :msg do
        \\    case validate(input) do
        \\      :ok -> reply :success
        \\      :error -> reply :failure
        \\    end
        \\  end
        \\end
    );
    const nodes = try parser.parseFile();
    const handler = nodes[0].kind.actor_def.body[0].kind.message_handler;
    const case_node = handler.body[0].kind.case_expr;

    // Subject should be a function call
    const subject_call = case_node.subject.kind.func_call;
    try std.testing.expectEqualStrings("validate", subject_call.name);
    try std.testing.expectEqual(@as(usize, 1), subject_call.args.len);

    // Two branches
    try std.testing.expectEqual(@as(usize, 2), case_node.branches.len);
    try std.testing.expectEqualStrings("ok", case_node.branches[0].pattern.?.kind.atom_lit.name);
    try std.testing.expectEqualStrings("error", case_node.branches[1].pattern.?.kind.atom_lit.name);
}

test "parse case with multiple body statements" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(arena.allocator(),
        \\actor A do
        \\  on :msg do
        \\    case status do
        \\      :active -> become count: 1
        \\        reply :ok
        \\      :inactive -> reply :error
        \\    end
        \\  end
        \\end
    );
    const nodes = try parser.parseFile();
    const handler = nodes[0].kind.actor_def.body[0].kind.message_handler;
    const case_node = handler.body[0].kind.case_expr;

    // First branch has 2 statements
    try std.testing.expectEqual(@as(usize, 2), case_node.branches[0].body.len);
    _ = case_node.branches[0].body[0].kind.become_stmt;
    _ = case_node.branches[0].body[1].kind.reply_stmt;

    // Second branch has 1 statement
    try std.testing.expectEqual(@as(usize, 1), case_node.branches[1].body.len);
}

test "parse dot-notation actor name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(arena.allocator(),
        \\actor Shop.Checkout do
        \\  state total: 0
        \\end
    );

    const nodes = try parser.parseFile();
    const actor = nodes[0].kind.actor_def;
    try std.testing.expectEqualStrings("Shop.Checkout", actor.name);
    try std.testing.expectEqual(@as(usize, 1), actor.body.len);
}

test "parse handler with tuple return type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(arena.allocator(),
        \\actor A do
        \\  on :deposit(amount: Int) -> {Atom, Int} do
        \\    reply {:ok, 42}
        \\  end
        \\end
    );

    const nodes = try parser.parseFile();
    const handler = nodes[0].kind.actor_def.body[0].kind.message_handler;
    try std.testing.expectEqualStrings("deposit", handler.name);
    try std.testing.expectEqualStrings("{Atom, Int}", handler.return_type.?);
}

test "parse handler with map return type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(arena.allocator(),
        \\actor A do
        \\  on :status -> %{String => Int} do
        \\    reply %{count: 42}
        \\  end
        \\end
    );

    const nodes = try parser.parseFile();
    const handler = nodes[0].kind.actor_def.body[0].kind.message_handler;
    try std.testing.expectEqualStrings("status", handler.name);
    try std.testing.expectEqualStrings("%{String => Int}", handler.return_type.?);
}

test "parse state with tuple type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(arena.allocator(),
        \\actor A do
        \\  state pair: {Int, String} :: {0, "x"}
        \\end
    );

    const nodes = try parser.parseFile();
    const state = nodes[0].kind.actor_def.body[0].kind.state_def;
    try std.testing.expectEqualStrings("{Int, String}", state.fields[0].type_name.?);
}

// === Bug 1: Multi-line handler signatures ===

test "parse multi-line handler with when on next line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(arena.allocator(),
        \\actor A do
        \\  on :charge(payment: Payment)
        \\      when valid?(payment) do
        \\    reply :ok
        \\  end
        \\end
    );

    const nodes = try parser.parseFile();
    const handler = nodes[0].kind.actor_def.body[0].kind.message_handler;
    try std.testing.expectEqualStrings("charge", handler.name);
    try std.testing.expect(handler.guard != null);
    const call = handler.guard.?.kind.func_call;
    try std.testing.expectEqualStrings("valid?", call.name);
}

test "parse multi-line handler with when and bubbles on separate lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(arena.allocator(),
        \\actor A do
        \\  on :charge(payment: Payment)
        \\      when valid?(payment)
        \\      bubbles(CascadeBubble) do
        \\    reply :ok
        \\  end
        \\end
    );

    const nodes = try parser.parseFile();
    const handler = nodes[0].kind.actor_def.body[0].kind.message_handler;
    try std.testing.expectEqualStrings("charge", handler.name);
    try std.testing.expect(handler.guard != null);
    try std.testing.expect(handler.bubble_strategy != null);
    try std.testing.expectEqualStrings("CascadeBubble", handler.bubble_strategy.?);
}

test "parse multi-line handler with return type on next line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(arena.allocator(),
        \\actor A do
        \\  on :get
        \\      -> Int do
        \\    reply 42
        \\  end
        \\end
    );

    const nodes = try parser.parseFile();
    const handler = nodes[0].kind.actor_def.body[0].kind.message_handler;
    try std.testing.expectEqualStrings("get", handler.name);
    try std.testing.expectEqualStrings("Int", handler.return_type.?);
}

// === Bug 2: Hole branches with comment directives ===

test "parse situation with hole comment directive" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(arena.allocator(),
        \\actor A do
        \\  on :msg do
        \\    situation x do
        \\      :ok -> reply 1
        \\      _
        \\    end
        \\  end
        \\end
    );

    const nodes = try parser.parseFile();
    const handler = nodes[0].kind.actor_def.body[0].kind.message_handler;
    const sit = handler.body[0].kind.situation;

    try std.testing.expectEqual(@as(usize, 2), sit.branches.len);

    // First branch: :ok -> reply 1
    try std.testing.expectEqualStrings("ok", sit.branches[0].pattern.?.kind.atom_lit.name);

    // Second branch: _ (hole, no arrow, no body)
    try std.testing.expect(sit.branches[1].pattern == null);
    try std.testing.expectEqual(@as(usize, 0), sit.branches[1].body.len);
}
