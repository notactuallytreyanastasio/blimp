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

// ============================================================
// Actor Registry: cross-actor type information
// ============================================================

/// Signature of a single message handler.
pub const HandlerSig = struct {
    param_names: []const []const u8,
    param_types: []const Type,
    return_type: ?Type,
};

/// State field entry: a name and its type.
const StateField = struct {
    name: []const u8,
    ty: Type,
};

/// Handler entry: a message name and its signature.
const HandlerEntry = struct {
    name: []const u8,
    sig: HandlerSig,
};

/// All type information for a single actor.
pub const ActorInfo = struct {
    state_fields: std.ArrayList(StateField),
    handlers: std.ArrayList(HandlerEntry),

    fn init() ActorInfo {
        return .{
            .state_fields = .{ .items = &.{}, .capacity = 0 },
            .handlers = .{ .items = &.{}, .capacity = 0 },
        };
    }

    /// Look up a state field type by name.
    pub fn lookupStateField(self: *const ActorInfo, name: []const u8) ?Type {
        for (self.state_fields.items) |sf| {
            if (std.mem.eql(u8, sf.name, name)) return sf.ty;
        }
        return null;
    }

    /// Look up a handler signature by message name.
    pub fn lookupHandler(self: *const ActorInfo, name: []const u8) ?HandlerSig {
        for (self.handlers.items) |h| {
            if (std.mem.eql(u8, h.name, name)) return h.sig;
        }
        return null;
    }
};

/// Registry entry: an actor name and its info.
const RegistryEntry = struct {
    name: []const u8,
    info: ActorInfo,
};

/// Registry of all actors and their type information.
/// Uses ArrayList with linear search (small number of actors).
pub const ActorRegistry = struct {
    entries: std.ArrayList(RegistryEntry),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ActorRegistry {
        return .{
            .entries = .{ .items = &.{}, .capacity = 0 },
            .allocator = allocator,
        };
    }

    /// Register a new actor (or get existing). Returns a pointer to its ActorInfo.
    pub fn register(self: *ActorRegistry, name: []const u8) *ActorInfo {
        // Check if already registered
        for (self.entries.items) |*entry| {
            if (std.mem.eql(u8, entry.name, name)) return &entry.info;
        }
        // Create new entry
        self.entries.append(self.allocator, .{
            .name = name,
            .info = ActorInfo.init(),
        }) catch return &self.entries.items[0].info; // fallback (shouldn't happen with arena)
        return &self.entries.items[self.entries.items.len - 1].info;
    }

    /// Look up an actor by name.
    pub fn lookupActor(self: *const ActorRegistry, name: []const u8) ?*const ActorInfo {
        for (self.entries.items) |*entry| {
            if (std.mem.eql(u8, entry.name, name)) return &entry.info;
        }
        return null;
    }
};

// ============================================================
// Built-in function signatures
// ============================================================

/// Represents a built-in function's type signature.
/// Uses a tag to describe polymorphic behavior.
const BuiltinKind = enum {
    /// length([T]) -> Int
    length,
    /// max(Int, Int) -> Int
    max,
    /// min(Int, Int) -> Int
    min,
    /// remove([T], T) -> [T]
    remove,
    /// append([T], T) -> [T]
    append_fn,
    /// lookup(%{K => V}, K) -> V
    lookup_fn,
    /// insert(%{K => V}, K, V) -> %{K => V}
    insert_fn,
    /// keys(%{K => V}) -> [K]
    keys,
    /// now() -> Int
    now,
    /// validate(Any) -> Atom
    validate,
};

const BuiltinEntry = struct {
    name: []const u8,
    kind: BuiltinKind,
};

const builtins = [_]BuiltinEntry{
    .{ .name = "length", .kind = .length },
    .{ .name = "max", .kind = .max },
    .{ .name = "min", .kind = .min },
    .{ .name = "remove", .kind = .remove },
    .{ .name = "append", .kind = .append_fn },
    .{ .name = "lookup", .kind = .lookup_fn },
    .{ .name = "insert", .kind = .insert_fn },
    .{ .name = "keys", .kind = .keys },
    .{ .name = "now", .kind = .now },
    .{ .name = "validate", .kind = .validate },
};

fn lookupBuiltin(name: []const u8) ?BuiltinKind {
    for (&builtins) |*b| {
        if (std.mem.eql(u8, b.name, name)) return b.kind;
    }
    return null;
}

/// Type checker: walks the AST and validates types.
pub const Checker = struct {
    allocator: std.mem.Allocator,
    env: TypeEnv,
    errors: std.ArrayList(TypeError),
    registry: ActorRegistry,
    /// The name of the actor currently being checked (for self-send resolution).
    current_actor: ?[]const u8,

    pub fn init(allocator: std.mem.Allocator) Checker {
        return .{
            .allocator = allocator,
            .env = TypeEnv.init(allocator),
            .errors = .{ .items = &.{}, .capacity = 0 },
            .registry = ActorRegistry.init(allocator),
            .current_actor = null,
        };
    }

    /// Check a complete file (list of top-level nodes).
    /// Two-pass approach:
    ///   Pass 1: Collect actor state fields and handler signatures into the registry.
    ///   Pass 2: Type-check bodies with full cross-actor knowledge.
    pub fn checkFile(self: *Checker, nodes: []const Node) CheckResult {
        // Pass 1: register all actors, their state fields, and handler signatures
        for (nodes) |node| {
            switch (node.kind) {
                .actor_def => |a| self.registerActor(a),
                else => {},
            }
        }
        // Pass 2: type-check bodies
        for (nodes) |node| {
            self.checkNode(node);
        }
        return .{
            .errors = self.errors.toOwnedSlice(self.allocator) catch &.{},
        };
    }

    /// Pass 1: Walk an actor definition and register its state fields and handler signatures.
    fn registerActor(self: *Checker, actor: Node.ActorDef) void {
        const info = self.registry.register(actor.name);
        for (actor.body) |stmt| {
            switch (stmt.kind) {
                .state_def => |s| {
                    for (s.fields) |field| {
                        if (field.type_name) |tn| {
                            const field_type = types.parseTypeName(self.allocator, tn) catch .hole;
                            info.state_fields.append(self.allocator, .{
                                .name = field.key,
                                .ty = field_type,
                            }) catch {};
                        }
                    }
                },
                .message_handler => |h| {
                    var p_names: std.ArrayList([]const u8) = .{ .items = &.{}, .capacity = 0 };
                    var p_types: std.ArrayList(Type) = .{ .items = &.{}, .capacity = 0 };
                    for (h.params) |param| {
                        p_names.append(self.allocator, param.name) catch {};
                        if (param.type_name) |tn| {
                            p_types.append(self.allocator, types.parseTypeName(self.allocator, tn) catch .hole) catch {};
                        } else {
                            p_types.append(self.allocator, .any) catch {};
                        }
                    }
                    var ret_type: ?Type = null;
                    if (h.return_type) |rt| {
                        ret_type = types.parseTypeName(self.allocator, rt) catch .hole;
                    }
                    info.handlers.append(self.allocator, .{
                        .name = h.name,
                        .sig = .{
                            .param_names = p_names.toOwnedSlice(self.allocator) catch &.{},
                            .param_types = p_types.toOwnedSlice(self.allocator) catch &.{},
                            .return_type = ret_type,
                        },
                    }) catch {};
                },
                else => {},
            }
        }
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
            .def_stmt => |d| self.checkDefStmt(d, node.loc),
            .fn_expr => |f| self.checkFnExpr(f, node.loc),
            // Expression statements: infer type to trigger any errors (e.g., message sends)
            .message_send, .func_call, .pipe_expr, .dot_access => {
                _ = self.inferExpr(node);
            },
            else => {},
        }
    }

    /// Check an actor definition: push scope, check body, pop scope.
    fn checkActorDef(self: *Checker, actor: Node.ActorDef, _: Loc) void {
        const prev_actor = self.current_actor;
        self.current_actor = actor.name;
        self.env.pushScope();
        for (actor.body) |stmt| {
            self.checkNode(stmt);
        }
        self.env.popScope();
        self.current_actor = prev_actor;
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

    /// Check a def statement: parameters must have type annotations.
    fn checkDefStmt(self: *Checker, def: Node.DefStmt, loc: Loc) void {
        self.env.pushScope();

        for (def.params) |param| {
            if (param.type_name) |tn| {
                const param_type = types.parseTypeName(self.allocator, tn) catch .hole;
                self.env.define(param.name, param_type);
            } else {
                self.addError(loc, "function parameter '{s}' is missing a type annotation", .{param.name});
                self.env.define(param.name, .any);
            }
        }

        for (def.body) |stmt| {
            self.checkNode(stmt);
        }

        self.env.popScope();
    }

    /// Check an fn expression: parameters must have type annotations.
    fn checkFnExpr(self: *Checker, f: Node.FnExpr, loc: Loc) void {
        for (f.params) |param| {
            if (param.type_name == null) {
                self.addError(loc, "lambda parameter '{s}' is missing a type annotation", .{param.name});
            }
        }
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
            .func_call => |fc| self.inferFuncCall(fc, node.loc),
            .pipe_expr => |pe| self.inferPipeExpr(pe),
            .dot_access => |da| self.inferDotAccess(da, node.loc),
            .message_send => |ms| self.inferMessageSend(ms, node.loc),
            .orelse_expr => |oe| self.inferExpr(oe.try_expr.*),
            .spawn_expr => |se| Type{ .actor = se.actor_name },
            .struct_lit => |sl| Type{ .actor = sl.type_name },
            .fn_expr => |f| blk: {
                self.checkFnExpr(f, node.loc);
                break :blk .any; // closures are opaque at the type level
            },
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
            // Concatenation: ++
            .concat => .any, // returns list or string depending on operands
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

    /// Infer the return type of a function call using built-in signatures.
    fn inferFuncCall(self: *Checker, fc: Node.FuncCall, loc: Loc) Type {
        // Always infer all arguments (catches untyped lambdas in map/filter/reduce/etc.)
        for (fc.args) |arg| {
            _ = self.inferExpr(arg);
        }
        // Check if it's a known built-in function for return type
        if (lookupBuiltin(fc.name)) |kind| {
            return self.resolveBuiltinReturn(kind, fc.args, loc);
        }
        // Unknown function -- return hole
        return .hole;
    }

    /// Resolve the return type of a built-in function given its arguments.
    fn resolveBuiltinReturn(self: *Checker, kind: BuiltinKind, args: []const Node, loc: Loc) Type {
        switch (kind) {
            .length => {
                // length([T]) -> Int
                if (args.len != 1) {
                    self.addError(loc, "length() expects 1 argument, got {d}", .{args.len});
                    return .hole;
                }
                const arg_type = self.inferExpr(args[0]);
                const ok = switch (arg_type) {
                    .list, .hole, .any, .nil, .string, .map, .tuple => true,
                    else => false,
                };
                if (!ok) {
                    self.addError(loc, "length() expects a list, got {s}", .{arg_type.typeName()});
                }
                return .int;
            },
            .max, .min => {
                // max(Int, Int) -> Int, min(Int, Int) -> Int
                if (args.len != 2) {
                    const name: []const u8 = if (kind == .max) "max" else "min";
                    self.addError(loc, "{s}() expects 2 arguments, got {d}", .{ name, args.len });
                    return .hole;
                }
                const a = self.inferExpr(args[0]);
                const b = self.inferExpr(args[1]);
                if (a != .int and a != .hole and a != .any) {
                    self.addError(loc, "max/min expects Int arguments, got {s}", .{a.typeName()});
                }
                if (b != .int and b != .hole and b != .any) {
                    self.addError(loc, "max/min expects Int arguments, got {s}", .{b.typeName()});
                }
                return .int;
            },
            .remove => {
                // remove([T], T) -> [T]
                if (args.len != 2) {
                    self.addError(loc, "remove() expects 2 arguments, got {d}", .{args.len});
                    return .hole;
                }
                const list_type = self.inferExpr(args[0]);
                _ = self.inferExpr(args[1]);
                if (list_type == .list) return list_type;
                return .hole;
            },
            .append_fn => {
                // append([T], T) -> [T]
                if (args.len != 2) {
                    self.addError(loc, "append() expects 2 arguments, got {d}", .{args.len});
                    return .hole;
                }
                const list_type = self.inferExpr(args[0]);
                _ = self.inferExpr(args[1]);
                if (list_type == .list) return list_type;
                return .hole;
            },
            .lookup_fn => {
                // lookup(%{K => V}, K) -> V
                // lookup(%{name: String, age: Int}, "name") -> String
                if (args.len != 2) {
                    self.addError(loc, "lookup() expects 2 arguments, got {d}", .{args.len});
                    return .hole;
                }
                const map_type = self.inferExpr(args[0]);
                const key_type = self.inferExpr(args[1]);
                _ = key_type;
                if (map_type == .map) return map_type.map.value.*;
                // For record types, try to resolve the specific field type
                if (map_type == .record_type) {
                    // If the key is a string literal, look up the exact field
                    if (args[1].kind == .string_lit) {
                        const raw = args[1].kind.string_lit.value;
                        const key_name = if (raw.len >= 2 and raw[0] == '"')
                            raw[1 .. raw.len - 1]
                        else
                            raw;
                        if (map_type.recordField(key_name)) |field_ty| return field_ty.*;
                    }
                    return .any;
                }
                return .hole;
            },
            .insert_fn => {
                // insert(%{K => V}, K, V) -> %{K => V}
                if (args.len != 3) {
                    self.addError(loc, "insert() expects 3 arguments, got {d}", .{args.len});
                    return .hole;
                }
                const map_type = self.inferExpr(args[0]);
                _ = self.inferExpr(args[1]);
                _ = self.inferExpr(args[2]);
                if (map_type == .map) return map_type;
                return .hole;
            },
            .keys => {
                // keys(%{K => V}) -> [K]
                if (args.len != 1) {
                    self.addError(loc, "keys() expects 1 argument, got {d}", .{args.len});
                    return .hole;
                }
                const map_type = self.inferExpr(args[0]);
                if (map_type == .map) {
                    const key_ptr = self.allocator.create(Type) catch return .hole;
                    key_ptr.* = map_type.map.key.*;
                    return Type{ .list = key_ptr };
                }
                return .hole;
            },
            .now => {
                // now() -> Int
                if (args.len != 0) {
                    self.addError(loc, "now() expects 0 arguments, got {d}", .{args.len});
                }
                return .int;
            },
            .validate => {
                // validate(Any) -> Atom
                if (args.len != 1) {
                    self.addError(loc, "validate() expects 1 argument, got {d}", .{args.len});
                    return .hole;
                }
                _ = self.inferExpr(args[0]);
                return .atom;
            },
        }
    }

    /// Infer the result type of a pipe expression.
    /// items |> length(_) => infer the right side (the function call gets the piped value).
    fn inferPipeExpr(self: *Checker, pe: Node.PipeExpr) Type {
        _ = self.inferExpr(pe.left.*);
        return self.inferExpr(pe.right.*);
    }

    /// Infer the type of a dot access expression.
    /// If the object has a known actor type, look up the field in the registry.
    /// Also handles dotted actor names: Shop.Checkout resolves to actor type.
    fn inferDotAccess(self: *Checker, da: Node.DotAccess, _: Loc) Type {
        // First, try to resolve as a dotted actor name (e.g., Shop.Checkout)
        if (flattenDottedNameForChecker(da, self.allocator)) |dotted_name| {
            if (self.registry.lookupActor(dotted_name) != null) {
                return Type{ .actor = dotted_name };
            }
        }

        const obj_type = self.inferExpr(da.object.*);
        // If the object is an actor type, look up the field in the registry
        if (obj_type == .actor) {
            if (self.registry.lookupActor(obj_type.actor)) |info| {
                if (info.lookupStateField(da.field)) |field_type| {
                    return field_type;
                }
            }
        }
        return .hole;
    }

    /// Infer the return type of a message send expression.
    /// target <- :message(args) => look up the target actor and handler in the registry.
    fn inferMessageSend(self: *Checker, ms: Node.MessageSend, loc: Loc) Type {
        // Try to determine which actor the target refers to
        const target_actor_name = self.resolveActorName(ms.target.*);
        if (target_actor_name) |actor_name| {
            if (self.registry.lookupActor(actor_name)) |info| {
                if (info.lookupHandler(ms.message)) |sig| {
                    // Check argument count
                    if (ms.args.len != sig.param_types.len) {
                        self.addError(loc, "message :{s} expects {d} argument(s), got {d}", .{
                            ms.message,
                            sig.param_types.len,
                            ms.args.len,
                        });
                    } else {
                        // Check argument types
                        for (ms.args, sig.param_types, 0..) |arg, expected, i| {
                            const arg_type = self.inferExpr(arg);
                            if (!arg_type.isSubtypeOf(expected)) {
                                self.addError(arg.loc, "argument {d} to :{s} expected {s}, got {s}", .{
                                    i + 1,
                                    ms.message,
                                    expected.typeName(),
                                    arg_type.typeName(),
                                });
                            }
                        }
                    }
                    return sig.return_type orelse .hole;
                }
            }
        }
        // Infer args even if we can't resolve the target (for error propagation)
        for (ms.args) |arg| {
            _ = self.inferExpr(arg);
        }
        return .hole;
    }

    /// Try to resolve an expression to an actor name for message send targets.
    /// Handles: identifiers that are known actor names, variables with actor types,
    /// and dot_access chains representing dotted actor names (e.g., Shop.Checkout).
    fn resolveActorName(self: *Checker, node: Node) ?[]const u8 {
        switch (node.kind) {
            .identifier => |id| {
                // Check if identifier is a registered actor name directly
                if (self.registry.lookupActor(id.name) != null) return id.name;
                // Check if the identifier has an actor type in the environment
                if (self.env.lookup(id.name)) |ty| {
                    if (ty == .actor) return ty.actor;
                }
                return null;
            },
            .dot_access => |da| {
                // Flatten the DotAccess chain into a dotted name (e.g., "Shop.Checkout")
                const dotted_name = flattenDottedNameForChecker(da, self.allocator) orelse return null;
                if (self.registry.lookupActor(dotted_name) != null) return dotted_name;
                return null;
            },
            else => return null,
        }
    }

    /// Flatten a DotAccess chain into a dotted name string for type checking.
    /// e.g., DotAccess(identifier("Shop"), "Checkout") -> "Shop.Checkout"
    fn flattenDottedNameForChecker(da: Node.DotAccess, allocator: std.mem.Allocator) ?[]const u8 {
        var parts: [16][]const u8 = undefined;
        var count: usize = 0;

        parts[count] = da.field;
        count += 1;

        var current = da.object;
        while (true) {
            switch (current.kind) {
                .dot_access => |inner_da| {
                    if (count >= 16) return null;
                    parts[count] = inner_da.field;
                    count += 1;
                    current = inner_da.object;
                },
                .identifier => |id| {
                    if (count >= 16) return null;
                    parts[count] = id.name;
                    count += 1;
                    break;
                },
                else => return null,
            }
        }

        // Build the dotted name from parts (in reverse order)
        var total_len: usize = count - 1; // dots
        for (parts[0..count]) |part| {
            total_len += part.len;
        }

        const buf = allocator.alloc(u8, total_len) catch return null;
        var pos: usize = 0;
        var i: usize = count;
        while (i > 0) {
            i -= 1;
            @memcpy(buf[pos .. pos + parts[i].len], parts[i]);
            pos += parts[i].len;
            if (i > 0) {
                buf[pos] = '.';
                pos += 1;
            }
        }

        return buf;
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

// ============================================================
// Actor Registry tests
// ============================================================

test "registry collects actor state fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var checker = Checker.init(alloc);
    var parser = @import("parser.zig").Parser.init(alloc,
        \\actor Counter do
        \\  state count: Int :: 0
        \\  state name: String :: "bob"
        \\end
    );
    const nodes = parser.parseFile() catch unreachable;
    _ = checker.checkFile(nodes);

    // Registry should have Counter with two state fields
    const info = checker.registry.lookupActor("Counter");
    try std.testing.expect(info != null);
    try std.testing.expectEqual(@as(usize, 2), info.?.state_fields.items.len);
    try std.testing.expect(info.?.lookupStateField("count").?.eql(.int));
    try std.testing.expect(info.?.lookupStateField("name").?.eql(.string));
}

test "registry collects handler signatures" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var checker = Checker.init(alloc);
    var parser = @import("parser.zig").Parser.init(alloc,
        \\actor Cart do
        \\  state total: Int :: 0
        \\  on :add(item: Item) -> Int do
        \\    reply 1
        \\  end
        \\  on :clear do
        \\    become total: 0
        \\  end
        \\end
    );
    const nodes = parser.parseFile() catch unreachable;
    _ = checker.checkFile(nodes);

    const info = checker.registry.lookupActor("Cart");
    try std.testing.expect(info != null);
    try std.testing.expectEqual(@as(usize, 2), info.?.handlers.items.len);

    // :add handler
    const add_sig = info.?.lookupHandler("add");
    try std.testing.expect(add_sig != null);
    try std.testing.expectEqual(@as(usize, 1), add_sig.?.param_types.len);
    try std.testing.expect(add_sig.?.return_type != null);
    try std.testing.expect(add_sig.?.return_type.?.eql(.int));

    // :clear handler
    const clear_sig = info.?.lookupHandler("clear");
    try std.testing.expect(clear_sig != null);
    try std.testing.expectEqual(@as(usize, 0), clear_sig.?.param_types.len);
    try std.testing.expect(clear_sig.?.return_type == null);
}

test "registry collects multiple actors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var checker = Checker.init(alloc);
    var parser = @import("parser.zig").Parser.init(alloc,
        \\actor Counter do
        \\  state count: Int :: 0
        \\  on :increment do
        \\    become count: count + 1
        \\  end
        \\end
        \\actor Logger do
        \\  state messages: [String] :: []
        \\  on :log(msg: String) do
        \\    reply :ok
        \\  end
        \\end
    );
    const nodes = parser.parseFile() catch unreachable;
    _ = checker.checkFile(nodes);

    try std.testing.expect(checker.registry.lookupActor("Counter") != null);
    try std.testing.expect(checker.registry.lookupActor("Logger") != null);
    try std.testing.expect(checker.registry.lookupActor("Missing") == null);
}

// ============================================================
// Message send type checking tests
// ============================================================

test "message send resolves return type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = testCheckWithArena(
        \\actor Cart do
        \\  state total: Int :: 0
        \\  on :total -> Int do
        \\    reply total
        \\  end
        \\end
        \\actor Cashier do
        \\  on :checkout do
        \\    result = Cart <- :total
        \\    reply result
        \\  end
        \\end
    , &arena);
    try std.testing.expectEqual(@as(usize, 0), result.errors.len);
}

test "message send with correct arg type passes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = testCheckWithArena(
        \\actor Cart do
        \\  state total: Int :: 0
        \\  on :add(amount: Int) -> Atom do
        \\    become total: total + amount
        \\    reply :ok
        \\  end
        \\end
        \\actor Cashier do
        \\  on :process do
        \\    Cart <- :add(42)
        \\  end
        \\end
    , &arena);
    try std.testing.expectEqual(@as(usize, 0), result.errors.len);
}

test "message send with wrong arg type produces error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = testCheckWithArena(
        \\actor Cart do
        \\  state total: Int :: 0
        \\  on :add(amount: Int) -> Atom do
        \\    become total: total + amount
        \\    reply :ok
        \\  end
        \\end
        \\actor Cashier do
        \\  on :process do
        \\    Cart <- :add("not a number")
        \\  end
        \\end
    , &arena);
    try std.testing.expectEqual(@as(usize, 1), result.errors.len);
    try std.testing.expect(std.mem.indexOf(u8, result.errors[0].message, "expected Int, got String") != null);
}

test "message send with wrong arg count produces error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = testCheckWithArena(
        \\actor Cart do
        \\  state total: Int :: 0
        \\  on :add(amount: Int) do
        \\    become total: total + amount
        \\  end
        \\end
        \\actor Cashier do
        \\  on :process do
        \\    Cart <- :add(1, 2)
        \\  end
        \\end
    , &arena);
    try std.testing.expectEqual(@as(usize, 1), result.errors.len);
    try std.testing.expect(std.mem.indexOf(u8, result.errors[0].message, "expects 1 argument(s), got 2") != null);
}

test "message send to unknown actor returns hole" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = testCheckWithArena(
        \\actor A do
        \\  on :go do
        \\    unknown <- :msg
        \\  end
        \\end
    , &arena);
    // No error for unknown targets -- just returns hole
    try std.testing.expectEqual(@as(usize, 0), result.errors.len);
}

// ============================================================
// Dot access tests
// ============================================================

test "dot access on actor-typed variable resolves field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var checker = Checker.init(alloc);
    // Manually register an actor with a state field
    const info = checker.registry.register("Item");
    info.state_fields.append(alloc, .{ .name = "price", .ty = .float }) catch unreachable;

    // Define a variable with actor type "Item"
    checker.env.define("item", Type{ .actor = "Item" });

    // Build: item.price
    const obj_node = Node{ .kind = .{ .identifier = .{ .name = "item" } }, .loc = .{ .line = 1, .col = 1 } };
    const obj_ptr = alloc.create(Node) catch unreachable;
    obj_ptr.* = obj_node;
    const dot_node = Node{
        .kind = .{ .dot_access = .{ .object = obj_ptr, .field = "price" } },
        .loc = .{ .line = 1, .col = 1 },
    };
    const result = checker.inferExpr(dot_node);
    try std.testing.expect(result.eql(.float));
}

test "dot access on unknown type returns hole" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var checker = Checker.init(alloc);
    checker.env.define("x", .int);

    const obj_node = Node{ .kind = .{ .identifier = .{ .name = "x" } }, .loc = .{ .line = 1, .col = 1 } };
    const obj_ptr = alloc.create(Node) catch unreachable;
    obj_ptr.* = obj_node;
    const dot_node = Node{
        .kind = .{ .dot_access = .{ .object = obj_ptr, .field = "foo" } },
        .loc = .{ .line = 1, .col = 1 },
    };
    const result = checker.inferExpr(dot_node);
    try std.testing.expect(result.eql(.hole));
}

test "dot access on unregistered actor returns hole" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var checker = Checker.init(alloc);
    checker.env.define("item", Type{ .actor = "UnknownActor" });

    const obj_node = Node{ .kind = .{ .identifier = .{ .name = "item" } }, .loc = .{ .line = 1, .col = 1 } };
    const obj_ptr = alloc.create(Node) catch unreachable;
    obj_ptr.* = obj_node;
    const dot_node = Node{
        .kind = .{ .dot_access = .{ .object = obj_ptr, .field = "price" } },
        .loc = .{ .line = 1, .col = 1 },
    };
    const result = checker.inferExpr(dot_node);
    try std.testing.expect(result.eql(.hole));
}

// ============================================================
// Built-in function tests
// ============================================================

test "length returns Int" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var checker = Checker.init(alloc);
    const elems = [_]Node{
        .{ .kind = .{ .integer_lit = .{ .value = 1 } }, .loc = .{ .line = 1, .col = 2 } },
    };
    const list_arg = Node{
        .kind = .{ .list_lit = .{ .elements = &elems, .tail = null } },
        .loc = .{ .line = 1, .col = 1 },
    };
    const args = [_]Node{list_arg};
    const call_node = Node{
        .kind = .{ .func_call = .{ .name = "length", .args = &args } },
        .loc = .{ .line = 1, .col = 1 },
    };
    const result = checker.inferExpr(call_node);
    try std.testing.expect(result.eql(.int));
}

test "max returns Int" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var checker = Checker.init(alloc);
    const args = [_]Node{
        .{ .kind = .{ .integer_lit = .{ .value = 1 } }, .loc = .{ .line = 1, .col = 5 } },
        .{ .kind = .{ .integer_lit = .{ .value = 2 } }, .loc = .{ .line = 1, .col = 8 } },
    };
    const call_node = Node{
        .kind = .{ .func_call = .{ .name = "max", .args = &args } },
        .loc = .{ .line = 1, .col = 1 },
    };
    const result = checker.inferExpr(call_node);
    try std.testing.expect(result.eql(.int));
}

test "min returns Int" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var checker = Checker.init(alloc);
    const args = [_]Node{
        .{ .kind = .{ .integer_lit = .{ .value = 5 } }, .loc = .{ .line = 1, .col = 5 } },
        .{ .kind = .{ .integer_lit = .{ .value = 3 } }, .loc = .{ .line = 1, .col = 8 } },
    };
    const call_node = Node{
        .kind = .{ .func_call = .{ .name = "min", .args = &args } },
        .loc = .{ .line = 1, .col = 1 },
    };
    const result = checker.inferExpr(call_node);
    try std.testing.expect(result.eql(.int));
}

test "now returns Int" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var checker = Checker.init(alloc);
    const call_node = Node{
        .kind = .{ .func_call = .{ .name = "now", .args = &.{} } },
        .loc = .{ .line = 1, .col = 1 },
    };
    const result = checker.inferExpr(call_node);
    try std.testing.expect(result.eql(.int));
}

test "validate returns Atom" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var checker = Checker.init(alloc);
    const args = [_]Node{
        .{ .kind = .{ .integer_lit = .{ .value = 42 } }, .loc = .{ .line = 1, .col = 10 } },
    };
    const call_node = Node{
        .kind = .{ .func_call = .{ .name = "validate", .args = &args } },
        .loc = .{ .line = 1, .col = 1 },
    };
    const result = checker.inferExpr(call_node);
    try std.testing.expect(result.eql(.atom));
}

test "lookup returns map value type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var checker = Checker.init(alloc);
    // Create a map variable: %{String => Int}
    const key_ptr = alloc.create(Type) catch unreachable;
    key_ptr.* = .string;
    const val_ptr = alloc.create(Type) catch unreachable;
    val_ptr.* = .int;
    checker.env.define("stock", Type{ .map = .{ .key = key_ptr, .value = val_ptr } });

    const args = [_]Node{
        .{ .kind = .{ .identifier = .{ .name = "stock" } }, .loc = .{ .line = 1, .col = 8 } },
        .{ .kind = .{ .string_lit = .{ .value = "item" } }, .loc = .{ .line = 1, .col = 15 } },
    };
    const call_node = Node{
        .kind = .{ .func_call = .{ .name = "lookup", .args = &args } },
        .loc = .{ .line = 1, .col = 1 },
    };
    const result = checker.inferExpr(call_node);
    try std.testing.expect(result.eql(.int));
}

test "keys returns list of key type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var checker = Checker.init(alloc);
    const key_ptr = alloc.create(Type) catch unreachable;
    key_ptr.* = .string;
    const val_ptr = alloc.create(Type) catch unreachable;
    val_ptr.* = .int;
    checker.env.define("stock", Type{ .map = .{ .key = key_ptr, .value = val_ptr } });

    const args = [_]Node{
        .{ .kind = .{ .identifier = .{ .name = "stock" } }, .loc = .{ .line = 1, .col = 6 } },
    };
    const call_node = Node{
        .kind = .{ .func_call = .{ .name = "keys", .args = &args } },
        .loc = .{ .line = 1, .col = 1 },
    };
    const result = checker.inferExpr(call_node);
    try std.testing.expect(result == .list);
    try std.testing.expect(result.list.eql(.string));
}

test "unknown function returns hole" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var checker = Checker.init(alloc);
    const call_node = Node{
        .kind = .{ .func_call = .{ .name = "some_custom_fn", .args = &.{} } },
        .loc = .{ .line = 1, .col = 1 },
    };
    const result = checker.inferExpr(call_node);
    try std.testing.expect(result.eql(.hole));
}

test "length with wrong arg count produces error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var checker = Checker.init(alloc);
    const call_node = Node{
        .kind = .{ .func_call = .{ .name = "length", .args = &.{} } },
        .loc = .{ .line = 1, .col = 1 },
    };
    _ = checker.inferExpr(call_node);
    const errs = checker.errors.toOwnedSlice(alloc) catch &.{};
    try std.testing.expectEqual(@as(usize, 1), errs.len);
    try std.testing.expect(std.mem.indexOf(u8, errs[0].message, "expects 1 argument") != null);
}

test "length with non-list arg produces error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var checker = Checker.init(alloc);
    const args = [_]Node{
        .{ .kind = .{ .integer_lit = .{ .value = 42 } }, .loc = .{ .line = 1, .col = 8 } },
    };
    const call_node = Node{
        .kind = .{ .func_call = .{ .name = "length", .args = &args } },
        .loc = .{ .line = 1, .col = 1 },
    };
    _ = checker.inferExpr(call_node);
    const errs = checker.errors.toOwnedSlice(alloc) catch &.{};
    try std.testing.expectEqual(@as(usize, 1), errs.len);
    try std.testing.expect(std.mem.indexOf(u8, errs[0].message, "expects a list") != null);
}

// ============================================================
// Pipe expression inference tests
// ============================================================

test "pipe into built-in function resolves type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = testCheckWithArena(
        \\actor A do
        \\  state items: [Int] :: []
        \\  on :count -> Int do
        \\    reply items |> length(_)
        \\  end
        \\end
    , &arena);
    try std.testing.expectEqual(@as(usize, 0), result.errors.len);
}

// ============================================================
// Integration test: multi-actor cross-checking
// ============================================================

test "cross-actor message send type checks end-to-end" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = testCheckWithArena(
        \\actor Inventory do
        \\  state stock: %{String => Int} :: %{}
        \\  on :check(item_name: String) -> Int do
        \\    reply lookup(stock, item_name)
        \\  end
        \\end
        \\actor Shop do
        \\  on :query do
        \\    count = Inventory <- :check("widget")
        \\    reply count
        \\  end
        \\end
    , &arena);
    try std.testing.expectEqual(@as(usize, 0), result.errors.len);
}

test "cross-actor wrong type at send site" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = testCheckWithArena(
        \\actor Inventory do
        \\  state stock: %{String => Int} :: %{}
        \\  on :check(item_name: String) -> Int do
        \\    reply 0
        \\  end
        \\end
        \\actor Shop do
        \\  on :query do
        \\    Inventory <- :check(42)
        \\  end
        \\end
    , &arena);
    try std.testing.expectEqual(@as(usize, 1), result.errors.len);
    try std.testing.expect(std.mem.indexOf(u8, result.errors[0].message, "expected String, got Int") != null);
}
