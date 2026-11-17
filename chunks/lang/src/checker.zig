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

    pub fn init() ActorInfo {
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
    /// The `-> Type` of the handler whose body is being checked, so that a
    /// `reply` is held to it wherever it stands: inside a case branch as well
    /// as at the top of the body.  Null outside a handler, and inside a def
    /// or fn nested in one, whose reply is not the handler's.
    declared_return: ?Type,

    pub fn init(allocator: std.mem.Allocator) Checker {
        return .{
            .allocator = allocator,
            .env = TypeEnv.init(allocator),
            .errors = .{ .items = &.{}, .capacity = 0 },
            .registry = ActorRegistry.init(allocator),
            .current_actor = null,
            .declared_return = null,
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
            .reply_stmt => |r| self.checkReplyStmt(r, node.loc),
            .assign_stmt => |a| self.checkAssignStmt(a),
            .message_handler => |h| self.checkMessageHandler(h, node.loc),
            .def_stmt => |d| self.checkDefStmt(d, node.loc),
            .fn_expr => |f| self.checkFnExpr(f, node.loc),
            .test_def => |t| self.checkBody(t.body),
            .property_def => |p| self.checkBody(p.body),
            .given_stmt => |g| {
                _ = self.inferExpr(g.generator.*);
                // A generated value: its type is the generator's, which no
                // signature here records.
                self.env.define(g.name, .hole);
            },
            .bubble_stmt => |b| {
                if (b.reason) |r| _ = self.inferExpr(r.*);
            },
            // Anything else in statement position is an expression whose
            // value is dropped: `1 + :a` on a line of its own, a case, a
            // for, a try.  Inferring it is what checks it.
            else => {
                _ = self.inferExpr(node);
            },
        }
    }

    /// Check a body the interpreter runs in a scope of its own, so that
    /// nothing it assigns is visible after it: a test or property body.
    /// The for body, the catch body and every case or situation branch but
    /// `_ ->` are the same, and are checked the same way below.
    ///
    /// The scope is pushed and popped and the outer types are left alone.
    /// `x = 1; for i in [1] do x = 2 end; puts(x)` prints 1, and
    /// `x = nil; for i in [1, 2] do x = i end; y = x + 1` stops with TYPE
    /// MISMATCH at run time, so x is still Nil after the loop and the
    /// checker says so.
    fn checkBody(self: *Checker, body: []const Node) void {
        self.env.pushScope();
        for (body) |stmt| self.checkNode(stmt);
        self.env.popScope();
    }

    /// The body of a `_ ->` branch that is not the first branch.
    ///
    /// The interpreter runs a `_ ->` branch in the enclosing scope
    /// (evalSituationTail, `.wild => return self.evalBodyTail(...)`), so
    /// what it assigns is visible after the case, and the other branches
    /// run in a scope of their own, so what they assign is not:
    ///
    ///   x = 1; case 1 do 1 -> x = 2  _ -> 0 end; puts(x)   prints 1
    ///   x = 1; case 1 do _ -> x = 2 end; puts(x)           prints 2
    ///
    /// When the `_ ->` branch is first it always runs, and its body is
    /// checked in the enclosing scope like a try body.  When it is not, a
    /// name it assigns is after the case either its old type or its new
    /// one, depending on which branch ran, and the checker has no type for
    /// "one of the two".  Keeping either would let a run-time type error
    /// through on the other path, so an assignment that changes an outer
    /// name to a type that is not a subtype of the old one is reported.
    /// A name only this branch binds stays unbound afterwards.
    fn checkWildBranch(self: *Checker, body: []const Node) void {
        self.env.pushScope();
        for (body) |stmt| self.checkNode(stmt);
        const scopes = self.env.scopes.items;
        const inner = scopes[scopes.len - 1].bindings.items;
        self.env.popScope();
        for (inner, 0..) |b, i| {
            // Only the last binding of a name in the branch is its type at
            // the end of the branch.
            var later = false;
            for (inner[i + 1 ..]) |b2| {
                if (std.mem.eql(u8, b2.name, b.name)) later = true;
            }
            if (later) continue;
            const old = self.env.lookup(b.name) orelse continue;
            // Hole and Any on either side are subtypes both ways.
            if (b.ty.isSubtypeOf(old)) continue;
            const loc = if (body.len > 0) body[0].loc else Loc{ .line = 0, .col = 0 };
            self.addError(loc, "'{s}' is {s} before this case and the `_ ->` branch makes it {s}; only a `_ ->` branch's assignment is seen after the case, so afterwards it is either", .{
                b.name,
                old.typeName(),
                b.ty.typeName(),
            });
        }
    }

    /// Bind every name a pattern binds, as hole.  A pattern name is a fresh
    /// binding of whatever matched, not a use of an outer variable of the
    /// same name, so leaving it unbound would let an outer `n: Int` stand in
    /// for the `n` in `{:add, n} ->`.
    fn bindPattern(self: *Checker, pattern: Node) void {
        switch (pattern.kind) {
            .identifier => |id| self.env.define(id.name, .hole),
            .tuple_lit => |t| for (t.elements) |e| self.bindPattern(e),
            .list_lit => |l| {
                for (l.elements) |e| self.bindPattern(e);
                if (l.tail) |t| self.bindPattern(t.*);
            },
            .map_lit => |m| for (m.entries) |e| self.bindPattern(e.value),
            else => {},
        }
    }

    /// Check the subject, every guard and every branch body of a case or
    /// situation.  The result is hole: the checker does not join the
    /// branches' types.
    fn inferBranches(self: *Checker, subject: Node, branches: []const Node.Branch) Type {
        _ = self.inferExpr(subject);
        for (branches, 0..) |br, i| {
            if (br.mode == .wild) {
                // See checkWildBranch: the interpreter runs this body in
                // the enclosing scope.  First, it always runs.
                if (i == 0) {
                    for (br.body) |stmt| self.checkNode(stmt);
                } else {
                    self.checkWildBranch(br.body);
                }
                continue;
            }
            self.env.pushScope();
            if (br.pattern) |p| self.bindPattern(p.*);
            if (br.guard) |g| _ = self.inferExpr(g.*);
            for (br.body) |stmt| self.checkNode(stmt);
            self.env.popScope();
        }
        return .hole;
    }

    /// Check an actor definition: push scope, check body, pop scope.
    fn checkActorDef(self: *Checker, actor: Node.ActorDef, _: Loc) void {
        const prev_actor = self.current_actor;
        self.current_actor = actor.name;
        self.env.pushScope();
        for (actor.body) |stmt| {
            // checkNode would check an inner actor as if it stood at top
            // level, though registerActor never registered it.
            if (stmt.kind == .actor_def) {
                const inner = stmt.kind.actor_def.name;
                self.addError(stmt.loc, "nested actor `{s}` inside `{s}` at line {d} is not supported; define it at top level as `actor {s}.{s} do ... end`", .{ inner, actor.name, stmt.loc.line, actor.name, inner });
                continue;
            }
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

    /// Check a reply statement against the enclosing handler's `-> Type`.
    fn checkReplyStmt(self: *Checker, reply: Node.ReplyStmt, loc: Loc) void {
        const reply_type = self.inferExpr(reply.value.*);
        if (self.declared_return) |expected| {
            if (!reply_type.isSubtypeOf(expected)) {
                self.addError(loc, "reply type mismatch: expected {s}, got {s}", .{
                    expected.typeName(),
                    reply_type.typeName(),
                });
            }
        }
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

        if (handler.guard) |g| _ = self.inferExpr(g.*);

        // Parse the declared return type (if any); checkReplyStmt holds
        // every reply in the body to it, nested or not.
        const prev_return = self.declared_return;
        self.declared_return = null;
        if (handler.return_type) |rt| {
            self.declared_return = types.parseTypeName(self.allocator, rt) catch .hole;
        }

        for (handler.body) |stmt| self.checkNode(stmt);

        self.declared_return = prev_return;
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

        const prev_return = self.declared_return;
        self.declared_return = null;
        for (def.body) |stmt| {
            self.checkNode(stmt);
        }
        self.declared_return = prev_return;

        self.env.popScope();
    }

    /// Check an fn expression: parameters must have type annotations, and
    /// the body is checked with them bound, as a def's is.
    fn checkFnExpr(self: *Checker, f: Node.FnExpr, loc: Loc) void {
        self.env.pushScope();
        for (f.params) |param| {
            if (param.type_name) |tn| {
                self.env.define(param.name, types.parseTypeName(self.allocator, tn) catch .hole);
            } else {
                self.addError(loc, "lambda parameter '{s}' is missing a type annotation", .{param.name});
                self.env.define(param.name, .any);
            }
        }
        const prev_return = self.declared_return;
        self.declared_return = null;
        for (f.body) |stmt| self.checkNode(stmt);
        self.declared_return = prev_return;
        // A closure's assignments are its own: plain pop, no widening.
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
            .string_lit => |sl| blk: {
                if (sl.interp) |ip| {
                    // The parser parses each `#{...}` on its own, so the
                    // nodes in it carry locations counted from the start of
                    // the braces: line 1, col 1 for the first.  An error in
                    // one is reported at the string instead.
                    const first_new = self.errors.items.len;
                    for (ip.parts) |part| switch (part) {
                        .expr => |e| _ = self.inferExpr(e.*),
                        .text => {},
                    };
                    for (self.errors.items[first_new..]) |*e| e.loc = node.loc;
                }
                break :blk .string;
            },
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
            .orelse_expr => |oe| blk: {
                const t = self.inferExpr(oe.try_expr.*);
                _ = self.inferExpr(oe.fallback.*);
                break :blk t;
            },
            .spawn_expr => |se| blk: {
                for (se.overrides) |kv| _ = self.inferExpr(kv.value);
                break :blk Type{ .actor = se.actor_name };
            },
            .struct_lit => |sl| blk: {
                for (sl.fields) |kv| _ = self.inferExpr(kv.value);
                break :blk Type{ .actor = sl.type_name };
            },
            .fn_expr => |f| blk: {
                self.checkFnExpr(f, node.loc);
                break :blk .any; // closures are opaque at the type level
            },
            .case_expr => |c| self.inferBranches(c.subject.*, c.branches),
            .situation => |c| self.inferBranches(c.subject.*, c.branches),
            .try_catch => |tc| blk: {
                // The interpreter runs a try body in the enclosing scope:
                // `x = 1; try do x = 2 catch e do 0 end; puts(x)` prints 2,
                // and a name first bound in it is bound after it.  So it is
                // checked there, and x is the try body's type afterwards.
                // That is wrong only when the body bubbles before the
                // assignment and the catch falls through; the checker
                // takes the path where the body finished.
                for (tc.try_body) |stmt| self.checkNode(stmt);
                // The catch body has a scope of its own: its `x = 2`
                // leaves the outer x as it was.
                self.env.pushScope();
                if (tc.catch_var) |v| self.env.define(v, .hole);
                for (tc.catch_body) |stmt| self.checkNode(stmt);
                self.env.popScope();
                break :blk .hole;
            },
            .for_expr => |fe| blk: {
                _ = self.inferExpr(fe.iterable.*);
                self.env.pushScope();
                self.env.define(fe.var_name, .hole);
                // Its own scope, every iteration: the outer x is unchanged.
                for (fe.body) |stmt| self.checkNode(stmt);
                self.env.popScope();
                break :blk .hole;
            },
            .spread_map, .spread_each => |sp| blk: {
                _ = self.inferExpr(sp.iterable.*);
                _ = self.inferExpr(sp.func.*);
                break :blk .hole;
            },
            .range_expr => |r| blk: {
                _ = self.inferExpr(r.start.*);
                _ = self.inferExpr(r.end_val.*);
                break :blk .hole;
            },
            .call_expr => |ce| blk: {
                _ = self.inferExpr(ce.callee.*);
                for (ce.args) |a| _ = self.inferExpr(a);
                break :blk .hole;
            },
            // Statements, literals and self: nothing below them to check.
            .actor_def, .state_def, .message_handler, .become_stmt, .reply_stmt, .assign_stmt, .def_stmt, .bubble_stmt, .test_def, .property_def, .given_stmt, .self_ref => .hole,
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
                if (left_type != .bool_type and left_type != .hole and left_type != .any and left_type != .never) {
                    self.addError(loc, "logical operator expects Bool, got {s}", .{
                        left_type.typeName(),
                    });
                }
                if (right_type != .bool_type and right_type != .hole and right_type != .any and right_type != .never) {
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
        // Never is the type of an operand that was already reported:
        // reporting it again as "Never and Int" says nothing new.
        if (left == .never or right == .never) return .never;
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
        // Holes, any, and nil are always comparable; so is never, the type
        // of an operand whose error is already reported.
        if (left == .never or right == .never) return true;
        if (left == .hole or right == .hole) return true;
        if (left == .any or right == .any) return true;
        if (left == .nil or right == .nil) return true;
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
                if (operand_type == .never) return .never;
                self.addError(loc, "cannot negate {s}", .{operand_type.typeName()});
                return .never;
            },
            .not => {
                if (operand_type == .bool_type) return .bool_type;
                if (operand_type == .hole or operand_type == .any) return .hole;
                if (operand_type == .never) return .never;
                self.addError(loc, "logical not expects Bool, got {s}", .{operand_type.typeName()});
                return .never;
            },
        };
    }

    /// Infer a list literal type from its elements.
    fn inferListLit(self: *Checker, list: Node.ListLit) Type {
        // Every element and the tail are checked; the type is the first
        // element's, as it was.
        for (list.elements[@min(1, list.elements.len)..]) |e| _ = self.inferExpr(e);
        if (list.tail) |t| _ = self.inferExpr(t.*);
        if (list.elements.len == 0) return .nil; // empty list
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
        for (map.entries[@min(1, map.entries.len)..]) |e| _ = self.inferExpr(e.value);
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
        // Always infer all arguments (catches untyped lambdas in map/filter/reduce/etc.),
        // once: the builtin signatures below read these types instead of
        // inferring the arguments again, which reported every error in an
        // argument to length() or max() twice.
        const arg_types = self.allocator.alloc(Type, fc.args.len) catch return .hole;
        for (fc.args, 0..) |arg, i| {
            arg_types[i] = self.inferExpr(arg);
        }
        // Check if it's a known built-in function for return type
        if (lookupBuiltin(fc.name)) |kind| {
            return self.resolveBuiltinReturn(kind, fc.args, arg_types, loc);
        }
        // Unknown function -- return hole
        return .hole;
    }

    /// Resolve the return type of a built-in function given its arguments.
    fn resolveBuiltinReturn(self: *Checker, kind: BuiltinKind, args: []const Node, arg_types: []const Type, loc: Loc) Type {
        switch (kind) {
            .length => {
                // length([T]) -> Int
                if (args.len != 1) {
                    self.addError(loc, "length() expects 1 argument, got {d}", .{args.len});
                    return .hole;
                }
                const arg_type = arg_types[0];
                const ok = switch (arg_type) {
                    .list, .hole, .any, .nil, .string, .map, .tuple, .never => true,
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
                const a = arg_types[0];
                const b = arg_types[1];
                if (a != .int and a != .hole and a != .any and a != .never) {
                    self.addError(loc, "max/min expects Int arguments, got {s}", .{a.typeName()});
                }
                if (b != .int and b != .hole and b != .any and b != .never) {
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
                const list_type = arg_types[0];
                if (list_type == .list) return list_type;
                return .hole;
            },
            .append_fn => {
                // append([T], T) -> [T]
                if (args.len != 2) {
                    self.addError(loc, "append() expects 2 arguments, got {d}", .{args.len});
                    return .hole;
                }
                const list_type = arg_types[0];
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
                const map_type = arg_types[0];
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
                const map_type = arg_types[0];
                if (map_type == .map) return map_type;
                return .hole;
            },
            .keys => {
                // keys(%{K => V}) -> [K]
                if (args.len != 1) {
                    self.addError(loc, "keys() expects 1 argument, got {d}", .{args.len});
                    return .hole;
                }
                const map_type = arg_types[0];
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
                    // Any type is compatible -- could be an actor ref at runtime
                    if (ty == .any or ty == .hole) return id.name;
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

// The parser refuses an actor inside an actor, so the AST is built by hand.
// checkActorDef used to hand the inner actor_def to checkNode, which checked
// it as if it stood at top level, while registerActor skipped it: its
// handlers were type-checked against a registry that never heard of it.
test "an actor_def inside an actor body is a checker error, not a second top-level actor" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var parser = @import("parser.zig").Parser.init(alloc, "actor Shop do\nend\nactor Checkout do\nend\n");
    const parsed = try parser.parseFile();
    var inner = parsed[1];
    inner.loc = .{ .line = 2, .col = 3 };
    const body = try alloc.alloc(Node, 1);
    body[0] = inner;
    var outer = parsed[0];
    outer.kind.actor_def.body = body;

    var checker = Checker.init(alloc);
    const result = checker.checkFile(&.{outer});
    try std.testing.expectEqual(@as(usize, 1), result.errors.len);
    try std.testing.expectEqual(@as(u32, 2), result.errors[0].loc.line);
    try std.testing.expectEqualStrings(
        "nested actor `Checkout` inside `Shop` at line 2 is not supported; define it at top level as `actor Shop.Checkout do ... end`",
        result.errors[0].message,
    );
}
