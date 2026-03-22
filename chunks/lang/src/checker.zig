const std = @import("std");
const ast = @import("ast.zig");
const Node = ast.Node;
const Loc = ast.Loc;
const types = @import("types.zig");
const Type = types.Type;
const TypeEnv = types.TypeEnv;

/// A type error with source location and message.
pub const TypeError = struct {
    loc: Loc,
    message: []const u8,
};

/// Result of type checking a file.
pub const CheckResult = struct {
    errors: []const TypeError,
};

/// Type checker: walks the AST and validates types.
pub const Checker = struct {
    allocator: std.mem.Allocator,
    env: TypeEnv,
    errors: std.ArrayList(TypeError),

    pub fn init(allocator: std.mem.Allocator) Checker {
        return .{
            .allocator = allocator,
            .env = TypeEnv.init(allocator),
            .errors = .{ .items = &.{}, .capacity = 0 },
        };
    }

    /// Check a complete file (list of top-level nodes).
    pub fn checkFile(self: *Checker, nodes: []const Node) CheckResult {
        for (nodes) |node| {
            self.checkNode(node);
        }
        return .{
            .errors = self.errors.toOwnedSlice(self.allocator) catch &.{},
        };
    }

    /// Check a single AST node.
    fn checkNode(self: *Checker, node: Node) void {
        switch (node.kind) {
            .actor_def => |a| self.checkActorDef(a, node.loc),
            .state_def => |s| self.checkStateDef(s, node.loc),
            .become_stmt => |b| self.checkBecomeStmt(b, node.loc),
            .reply_stmt => |r| self.checkReplyStmt(r),
            .assign_stmt => |a| self.checkAssignStmt(a),
            .message_handler => |h| self.checkMessageHandler(h, node.loc),
            else => {},
        }
    }

    /// Check an actor definition: push scope, check body, pop scope.
    fn checkActorDef(self: *Checker, actor: Node.ActorDef, _: Loc) void {
        self.env.pushScope();
        for (actor.body) |stmt| {
            self.checkNode(stmt);
        }
        self.env.popScope();
    }

    /// Check state declarations: for each field with a type annotation and default value,
    /// verify the default matches the declared type.
    fn checkStateDef(self: *Checker, state: Node.StateDef, _: Loc) void {
        for (state.fields) |field| {
            if (field.type_name) |tn| {
                // Parse the declared type
                const declared = types.parseTypeName(self.allocator, tn) catch .hole;

                // Register the state field in the environment
                self.env.define(field.key, declared);

                // If there is a default value, check compatibility
                if (field.default_value != null) {
                    const val_type = self.inferExpr(field.value);
                    if (!val_type.isSubtypeOf(declared)) {
                        self.addError(field.value.loc, "type mismatch in state default: expected {s}, got {s}", .{
                            declared.typeName(),
                            val_type.typeName(),
                        });
                    }
                }
            } else {
                // Untyped state -- error in strict mode, but still register for continued checking
                self.addError(field.value.loc, "state field '{s}' is missing a type annotation", .{field.key});
                const val_type = self.inferExpr(field.value);
                self.env.define(field.key, val_type);
            }
        }
    }

    /// Check become statements: each field must match the declared state type.
    fn checkBecomeStmt(self: *Checker, become: Node.BecomeStmt, _: Loc) void {
        for (become.fields) |field| {
            const val_type = self.inferExpr(field.value);
            if (self.env.lookup(field.key)) |expected| {
                if (!val_type.isSubtypeOf(expected)) {
                    self.addError(field.value.loc, "type mismatch in become: field '{s}' expected {s}, got {s}", .{
                        field.key,
                        expected.typeName(),
                        val_type.typeName(),
                    });
                }
            }
            // If field not found in env, we skip (might be defined in a parent actor)
        }
    }

    /// Check a reply statement: just infer the type of the expression.
    fn checkReplyStmt(self: *Checker, reply: Node.ReplyStmt) void {
        _ = self.inferExpr(reply.value.*);
    }

    /// Check an assignment: infer the RHS type and bind the variable.
    fn checkAssignStmt(self: *Checker, assign: Node.AssignStmt) void {
        const val_type = self.inferExpr(assign.value.*);
        self.env.define(assign.name, val_type);
    }

    /// Check a message handler: enforce typed params, bind them, check body, verify return type.
    fn checkMessageHandler(self: *Checker, handler: Node.MessageHandler, loc: Loc) void {
        self.env.pushScope();

        // Parse and bind handler parameters -- types are required
        for (handler.params) |param| {
            if (param.type_name) |tn| {
                const param_type = types.parseTypeName(self.allocator, tn) catch .hole;
                self.env.define(param.name, param_type);
            } else {
                // No type annotation -- error, types are mandatory
                self.addError(loc, "handler parameter '{s}' is missing a type annotation", .{param.name});
                self.env.define(param.name, .any);
            }
        }

        // Parse the declared return type (if any)
        var declared_return: ?Type = null;
        if (handler.return_type) |rt| {
            declared_return = types.parseTypeName(self.allocator, rt) catch .hole;
        }

        // Check body and collect reply types
        for (handler.body) |stmt| {
            switch (stmt.kind) {
                .reply_stmt => |r| {
                    const reply_type = self.inferExpr(r.value.*);
                    if (declared_return) |expected| {
                        if (!reply_type.isSubtypeOf(expected)) {
                            self.addError(stmt.loc, "reply type mismatch: expected {s}, got {s}", .{
                                expected.typeName(),
                                reply_type.typeName(),
                            });
                        }
                    }
                },
                else => self.checkNode(stmt),
            }
        }

        self.env.popScope();
    }

    // ============================================================
    // Type inference for expressions
    // ============================================================

    /// Infer the type of an expression node.
    pub fn inferExpr(self: *Checker, node: Node) Type {
        return switch (node.kind) {
            .integer_lit => .int,
            .float_lit => .float,
            .string_lit => .string,
            .atom_lit => .atom,
            .bool_lit => .bool_type,
            .nil_lit => .nil,
            .hole => .hole,
            .identifier => |id| self.env.lookup(id.name) orelse .hole,
            .binary_op => |op| self.inferBinaryOp(op, node.loc),
            .unary_op => |op| self.inferUnaryOp(op, node.loc),
            .list_lit => |l| self.inferListLit(l),
            .tuple_lit => |t| self.inferTupleLit(t),
            .map_lit => |m| self.inferMapLit(m),
            .func_call => .hole, // Cannot infer without function signatures
            .pipe_expr => .hole, // Cannot infer pipe results yet
            .dot_access => .hole, // Cannot infer field access yet
            .message_send => .hole, // Cannot infer message send results yet
            .orelse_expr => |oe| self.inferExpr(oe.try_expr.*),
            .situation => .hole, // Cannot infer situation results yet
            else => .hole,
        };
    }

    /// Infer the type of a binary operation.
    fn inferBinaryOp(self: *Checker, op: Node.BinaryOp, loc: Loc) Type {
        const left_type = self.inferExpr(op.left.*);
        const right_type = self.inferExpr(op.right.*);

        return switch (op.op) {
            // Arithmetic: +, -, *, /
            .add, .sub, .mul, .div => self.checkArithmetic(left_type, right_type, loc, op.op),
            // Comparison: ==, !=, <, >, <=, >=
            .eq, .neq, .lt, .gt, .lte, .gte => blk: {
                // Both sides should be comparable (same type or numeric)
                if (!self.areComparable(left_type, right_type)) {
                    self.addError(loc, "cannot compare {s} with {s}", .{
                        left_type.typeName(),
                        right_type.typeName(),
                    });
                }
                break :blk .bool_type;
            },
            // Logical: &&, ||
            .and_op, .or_op => blk: {
                if (left_type != .bool_type and left_type != .hole and left_type != .any) {
                    self.addError(loc, "logical operator expects Bool, got {s}", .{
                        left_type.typeName(),
                    });
                }
                if (right_type != .bool_type and right_type != .hole and right_type != .any) {
                    self.addError(loc, "logical operator expects Bool, got {s}", .{
                        right_type.typeName(),
                    });
                }
                break :blk .bool_type;
            },
        };
    }

    /// Check arithmetic operations and return the result type.
    fn checkArithmetic(self: *Checker, left: Type, right: Type, loc: Loc, op: Node.BinaryOp.Op) Type {
        _ = op;
        // hole or any => permissive (unknown types don't cause errors)
        if (left == .hole or right == .hole) return .hole;
        if (left == .any or right == .any) return .any;

        // Int op Int => Int
        if (left == .int and right == .int) return .int;
        // Float op Float => Float
        if (left == .float and right == .float) return .float;
        // Int op Float or Float op Int => Float (promotion)
        if ((left == .int and right == .float) or
            (left == .float and right == .int)) return .float;

        // String concatenation with + is not supported (maybe later)
        self.addError(loc, "arithmetic on incompatible types: {s} and {s}", .{
            left.typeName(),
            right.typeName(),
        });
        return .never;
    }

    /// Check if two types can be compared.
    fn areComparable(self: *Checker, left: Type, right: Type) bool {
        _ = self;
        // Holes and any are always comparable (unknown type)
        if (left == .hole or right == .hole) return true;
        if (left == .any or right == .any) return true;
        // Same type tag is always comparable
        if (std.meta.activeTag(left) == std.meta.activeTag(right)) return true;
        // Numeric types are cross-comparable
        if ((left == .int or left == .float) and
            (right == .int or right == .float)) return true;
        return false;
    }

    /// Infer the type of a unary operation.
    fn inferUnaryOp(self: *Checker, op: Node.UnaryOp, loc: Loc) Type {
        const operand_type = self.inferExpr(op.operand.*);
        return switch (op.op) {
            .negate => {
                if (operand_type == .int) return .int;
                if (operand_type == .float) return .float;
                if (operand_type == .hole or operand_type == .any) return .hole;
                self.addError(loc, "cannot negate {s}", .{operand_type.typeName()});
                return .never;
            },
            .not => {
                if (operand_type == .bool_type) return .bool_type;
                if (operand_type == .hole or operand_type == .any) return .hole;
                self.addError(loc, "logical not expects Bool, got {s}", .{operand_type.typeName()});
                return .never;
            },
        };
    }

    /// Infer a list literal type from its elements.
    fn inferListLit(self: *Checker, list: Node.ListLit) Type {
        if (list.elements.len == 0) return .nil; // empty list
        // Infer from first element
        const first = self.inferExpr(list.elements[0]);
        const first_ptr = self.allocator.create(Type) catch return .hole;
        first_ptr.* = first;
        return Type{ .list = first_ptr };
    }

    /// Infer a tuple literal type from its elements.
    fn inferTupleLit(self: *Checker, tuple: Node.TupleLit) Type {
        const elem_types = self.allocator.alloc(Type, tuple.elements.len) catch return .hole;
        for (tuple.elements, 0..) |elem, i| {
            elem_types[i] = self.inferExpr(elem);
        }
        return Type{ .tuple = elem_types };
    }

    /// Infer a map literal type from its entries.
    fn inferMapLit(self: *Checker, map: Node.MapLit) Type {
        if (map.entries.len == 0) return .nil; // empty map
        // Infer from first entry: keys are atoms (shorthand syntax), values from expression
        const val_type = self.inferExpr(map.entries[0].value);
        const key_ptr = self.allocator.create(Type) catch return .hole;
        key_ptr.* = .atom;
        const val_ptr = self.allocator.create(Type) catch return .hole;
        val_ptr.* = val_type;
        return Type{ .map = .{ .key = key_ptr, .value = val_ptr } };
    }

    // ============================================================
    // Error reporting
    // ============================================================

    fn addError(self: *Checker, loc: Loc, comptime fmt: []const u8, args: anytype) void {
        const message = std.fmt.allocPrint(self.allocator, fmt, args) catch "type error";
        self.errors.append(self.allocator, .{ .loc = loc, .message = message }) catch {};
    }
};

// ============================================================
// Tests
// ============================================================

fn testCheckWithArena(source: []const u8, arena: *std.heap.ArenaAllocator) CheckResult {
    const alloc = arena.allocator();
    var parser = @import("parser.zig").Parser.init(alloc, source);
    const nodes = parser.parseFile() catch return .{ .errors = &.{} };
    var checker = Checker.init(alloc);
    return checker.checkFile(nodes);
}

test "well-typed state with int default" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = testCheckWithArena(
        \\actor Counter do
        \\  state count: Int :: 0
        \\end
    , &arena);
    try std.testing.expectEqual(@as(usize, 0), result.errors.len);
}

test "well-typed state with string default" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = testCheckWithArena(
        \\actor A do
        \\  state name: String :: "hello"
        \\end
    , &arena);
    try std.testing.expectEqual(@as(usize, 0), result.errors.len);
}

test "well-typed state with bool default" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = testCheckWithArena(
        \\actor A do
        \\  state active: Bool :: true
        \\end
    , &arena);
    try std.testing.expectEqual(@as(usize, 0), result.errors.len);
}

test "well-typed state with float default" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = testCheckWithArena(
        \\actor A do
        \\  state rate: Float :: 3.14
        \\end
    , &arena);
    try std.testing.expectEqual(@as(usize, 0), result.errors.len);
}

test "well-typed state int promoted to float" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = testCheckWithArena(
        \\actor A do
        \\  state rate: Float :: 0
        \\end
    , &arena);
    // Int is subtype of Float, so this should pass
    try std.testing.expectEqual(@as(usize, 0), result.errors.len);
}

test "ill-typed state - string default for int" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = testCheckWithArena(
        \\actor A do
        \\  state count: Int :: "hello"
        \\end
    , &arena);
    try std.testing.expectEqual(@as(usize, 1), result.errors.len);
    try std.testing.expect(std.mem.indexOf(u8, result.errors[0].message, "type mismatch") != null);
}

test "ill-typed state - int default for string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = testCheckWithArena(
        \\actor A do
        \\  state name: String :: 42
        \\end
    , &arena);
    try std.testing.expectEqual(@as(usize, 1), result.errors.len);
}

test "ill-typed state - bool default for int" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = testCheckWithArena(
        \\actor A do
        \\  state count: Int :: true
        \\end
    , &arena);
    try std.testing.expectEqual(@as(usize, 1), result.errors.len);
}

test "well-typed become" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = testCheckWithArena(
        \\actor Counter do
        \\  state count: Int :: 0
        \\  on :increment do
        \\    become count: count + 1
        \\  end
        \\end
    , &arena);
    try std.testing.expectEqual(@as(usize, 0), result.errors.len);
}

test "ill-typed become - string for int field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = testCheckWithArena(
        \\actor Counter do
        \\  state count: Int :: 0
        \\  on :reset do
        \\    become count: "zero"
        \\  end
        \\end
    , &arena);
    try std.testing.expectEqual(@as(usize, 1), result.errors.len);
    try std.testing.expect(std.mem.indexOf(u8, result.errors[0].message, "type mismatch") != null);
}

test "arithmetic type inference - int + int" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var checker = Checker.init(alloc);
    // Build: 1 + 2
    const left = Node{ .kind = .{ .integer_lit = .{ .value = 1 } }, .loc = .{ .line = 1, .col = 1 } };
    const right = Node{ .kind = .{ .integer_lit = .{ .value = 2 } }, .loc = .{ .line = 1, .col = 5 } };
    const left_ptr = alloc.create(Node) catch unreachable;
    left_ptr.* = left;
    const right_ptr = alloc.create(Node) catch unreachable;
    right_ptr.* = right;
    const add_node = Node{
        .kind = .{ .binary_op = .{ .op = .add, .left = left_ptr, .right = right_ptr } },
        .loc = .{ .line = 1, .col = 3 },
    };
    const result = checker.inferExpr(add_node);
    try std.testing.expect(result.eql(.int));
}

test "arithmetic type inference - int + float promotes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var checker = Checker.init(alloc);
    const left = Node{ .kind = .{ .integer_lit = .{ .value = 1 } }, .loc = .{ .line = 1, .col = 1 } };
    const right = Node{ .kind = .{ .float_lit = .{ .value = 2.5 } }, .loc = .{ .line = 1, .col = 5 } };
    const left_ptr = alloc.create(Node) catch unreachable;
    left_ptr.* = left;
    const right_ptr = alloc.create(Node) catch unreachable;
    right_ptr.* = right;
    const add_node = Node{
        .kind = .{ .binary_op = .{ .op = .add, .left = left_ptr, .right = right_ptr } },
        .loc = .{ .line = 1, .col = 3 },
    };
    const result = checker.inferExpr(add_node);
    try std.testing.expect(result.eql(.float));
}

test "arithmetic type error - string + int" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var checker = Checker.init(alloc);
    const left = Node{ .kind = .{ .string_lit = .{ .value = "hello" } }, .loc = .{ .line = 1, .col = 1 } };
    const right = Node{ .kind = .{ .integer_lit = .{ .value = 1 } }, .loc = .{ .line = 1, .col = 10 } };
    const left_ptr = alloc.create(Node) catch unreachable;
    left_ptr.* = left;
    const right_ptr = alloc.create(Node) catch unreachable;
    right_ptr.* = right;
    const add_node = Node{
        .kind = .{ .binary_op = .{ .op = .add, .left = left_ptr, .right = right_ptr } },
        .loc = .{ .line = 1, .col = 8 },
    };
    _ = checker.inferExpr(add_node);
    const errs = checker.errors.toOwnedSlice(alloc) catch &.{};
    try std.testing.expectEqual(@as(usize, 1), errs.len);
    try std.testing.expect(std.mem.indexOf(u8, errs[0].message, "incompatible types") != null);
}

test "comparison returns bool" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var checker = Checker.init(alloc);
    const left = Node{ .kind = .{ .integer_lit = .{ .value = 1 } }, .loc = .{ .line = 1, .col = 1 } };
    const right = Node{ .kind = .{ .integer_lit = .{ .value = 2 } }, .loc = .{ .line = 1, .col = 5 } };
    const left_ptr = alloc.create(Node) catch unreachable;
    left_ptr.* = left;
    const right_ptr = alloc.create(Node) catch unreachable;
    right_ptr.* = right;
    const cmp_node = Node{
        .kind = .{ .binary_op = .{ .op = .lt, .left = left_ptr, .right = right_ptr } },
        .loc = .{ .line = 1, .col = 3 },
    };
    const result = checker.inferExpr(cmp_node);
    try std.testing.expect(result.eql(.bool_type));
}

test "logical op expects bool" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var checker = Checker.init(alloc);
    const left = Node{ .kind = .{ .integer_lit = .{ .value = 1 } }, .loc = .{ .line = 1, .col = 1 } };
    const right = Node{ .kind = .{ .bool_lit = .{ .value = true } }, .loc = .{ .line = 1, .col = 5 } };
    const left_ptr = alloc.create(Node) catch unreachable;
    left_ptr.* = left;
    const right_ptr = alloc.create(Node) catch unreachable;
    right_ptr.* = right;
    const and_node = Node{
        .kind = .{ .binary_op = .{ .op = .and_op, .left = left_ptr, .right = right_ptr } },
        .loc = .{ .line = 1, .col = 3 },
    };
    _ = checker.inferExpr(and_node);
    const errs = checker.errors.toOwnedSlice(alloc) catch &.{};
    try std.testing.expectEqual(@as(usize, 1), errs.len);
    try std.testing.expect(std.mem.indexOf(u8, errs[0].message, "logical operator") != null);
}

test "unary negate on int" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var checker = Checker.init(alloc);
    const operand = Node{ .kind = .{ .integer_lit = .{ .value = 42 } }, .loc = .{ .line = 1, .col = 2 } };
    const operand_ptr = alloc.create(Node) catch unreachable;
    operand_ptr.* = operand;
    const neg_node = Node{
        .kind = .{ .unary_op = .{ .op = .negate, .operand = operand_ptr } },
        .loc = .{ .line = 1, .col = 1 },
    };
    const result = checker.inferExpr(neg_node);
    try std.testing.expect(result.eql(.int));
}

test "unary not on non-bool is error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var checker = Checker.init(alloc);
    const operand = Node{ .kind = .{ .integer_lit = .{ .value = 42 } }, .loc = .{ .line = 1, .col = 2 } };
    const operand_ptr = alloc.create(Node) catch unreachable;
    operand_ptr.* = operand;
    const not_node = Node{
        .kind = .{ .unary_op = .{ .op = .not, .operand = operand_ptr } },
        .loc = .{ .line = 1, .col = 1 },
    };
    _ = checker.inferExpr(not_node);
    const errs = checker.errors.toOwnedSlice(alloc) catch &.{};
    try std.testing.expectEqual(@as(usize, 1), errs.len);
}

test "list literal type inference" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var checker = Checker.init(alloc);
    const elems = [_]Node{
        .{ .kind = .{ .integer_lit = .{ .value = 1 } }, .loc = .{ .line = 1, .col = 2 } },
        .{ .kind = .{ .integer_lit = .{ .value = 2 } }, .loc = .{ .line = 1, .col = 5 } },
    };
    const list_node = Node{
        .kind = .{ .list_lit = .{ .elements = &elems, .tail = null } },
        .loc = .{ .line = 1, .col = 1 },
    };
    const result = checker.inferExpr(list_node);
    try std.testing.expect(result == .list);
    try std.testing.expect(result.list.eql(.int));
}

test "empty list is nil" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var checker = Checker.init(alloc);
    const list_node = Node{
        .kind = .{ .list_lit = .{ .elements = &.{}, .tail = null } },
        .loc = .{ .line = 1, .col = 1 },
    };
    const result = checker.inferExpr(list_node);
    try std.testing.expect(result.eql(.nil));
}

test "tuple literal type inference" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var checker = Checker.init(alloc);
    const elems = [_]Node{
        .{ .kind = .{ .atom_lit = .{ .name = "ok" } }, .loc = .{ .line = 1, .col = 2 } },
        .{ .kind = .{ .integer_lit = .{ .value = 42 } }, .loc = .{ .line = 1, .col = 6 } },
    };
    const tuple_node = Node{
        .kind = .{ .tuple_lit = .{ .elements = &elems } },
        .loc = .{ .line = 1, .col = 1 },
    };
    const result = checker.inferExpr(tuple_node);
    try std.testing.expect(result == .tuple);
    try std.testing.expectEqual(@as(usize, 2), result.tuple.len);
    try std.testing.expect(result.tuple[0].eql(.atom));
    try std.testing.expect(result.tuple[1].eql(.int));
}

test "well-typed state with list default" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = testCheckWithArena(
        \\actor Cart do
        \\  state items: [Item] :: []
        \\end
    , &arena);
    // nil is subtype of [Item], so empty list is valid
    try std.testing.expectEqual(@as(usize, 0), result.errors.len);
}

test "multiple state fields all checked" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = testCheckWithArena(
        \\actor A do
        \\  state count: Int :: 0, name: String :: "bob"
        \\end
    , &arena);
    try std.testing.expectEqual(@as(usize, 0), result.errors.len);
}

test "multiple state fields with one error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = testCheckWithArena(
        \\actor A do
        \\  state count: Int :: 0, name: String :: 42
        \\end
    , &arena);
    try std.testing.expectEqual(@as(usize, 1), result.errors.len);
}

test "identifier resolves from environment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var checker = Checker.init(alloc);
    checker.env.define("count", .int);

    const id_node = Node{
        .kind = .{ .identifier = .{ .name = "count" } },
        .loc = .{ .line = 1, .col = 1 },
    };
    const result = checker.inferExpr(id_node);
    try std.testing.expect(result.eql(.int));
}

test "unknown identifier returns hole" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var checker = Checker.init(alloc);
    const id_node = Node{
        .kind = .{ .identifier = .{ .name = "unknown" } },
        .loc = .{ .line = 1, .col = 1 },
    };
    const result = checker.inferExpr(id_node);
    try std.testing.expect(result.eql(.hole));
}

// ============================================================
// Explicit typing enforcement tests
// ============================================================

test "typed handler params are bound correctly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = testCheckWithArena(
        \\actor Cart do
        \\  state total: Int :: 0
        \\  on :add(amount: Int) do
        \\    become total: total + amount
        \\  end
        \\end
    , &arena);
    try std.testing.expectEqual(@as(usize, 0), result.errors.len);
}

test "untyped handler param produces error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = testCheckWithArena(
        \\actor Cart do
        \\  on :add(item) do
        \\    reply :ok
        \\  end
        \\end
    , &arena);
    try std.testing.expectEqual(@as(usize, 1), result.errors.len);
    try std.testing.expect(std.mem.indexOf(u8, result.errors[0].message, "missing a type annotation") != null);
}

test "return type mismatch produces error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = testCheckWithArena(
        \\actor A do
        \\  on :get -> Int do
        \\    reply "hello"
        \\  end
        \\end
    , &arena);
    try std.testing.expectEqual(@as(usize, 1), result.errors.len);
    try std.testing.expect(std.mem.indexOf(u8, result.errors[0].message, "reply type mismatch") != null);
}

test "return type match passes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = testCheckWithArena(
        \\actor A do
        \\  on :get -> Int do
        \\    reply 42
        \\  end
        \\end
    , &arena);
    try std.testing.expectEqual(@as(usize, 0), result.errors.len);
}

test "return type with int-to-float promotion passes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = testCheckWithArena(
        \\actor A do
        \\  on :rate -> Float do
        \\    reply 0
        \\  end
        \\end
    , &arena);
    try std.testing.expectEqual(@as(usize, 0), result.errors.len);
}

test "untyped state field produces error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = testCheckWithArena(
        \\actor A do
        \\  state count: 0
        \\end
    , &arena);
    try std.testing.expectEqual(@as(usize, 1), result.errors.len);
    try std.testing.expect(std.mem.indexOf(u8, result.errors[0].message, "missing a type annotation") != null);
}

test "multiple typed params all checked" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = testCheckWithArena(
        \\actor A do
        \\  state total: Int :: 0
        \\  on :transfer(from: String, amount: Int) do
        \\    become total: total + amount
        \\    reply :ok
        \\  end
        \\end
    , &arena);
    try std.testing.expectEqual(@as(usize, 0), result.errors.len);
}

test "handler with typed params, return type, guard, and bubbles" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = testCheckWithArena(
        \\actor Checkout do
        \\  state total: Int :: 0
        \\  on :charge(payment: Int) -> Atom when payment > 0 bubbles(CascadeBubble) do
        \\    reply :ok
        \\  end
        \\end
    , &arena);
    try std.testing.expectEqual(@as(usize, 0), result.errors.len);
}
