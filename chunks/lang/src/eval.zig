const std = @import("std");
const ast = @import("ast.zig");
const value_mod = @import("value.zig");
const Value = value_mod.Value;
const Environment = @import("env.zig").Environment;
const builtins_mod = @import("builtins.zig");
const BuiltinRegistry = builtins_mod.BuiltinRegistry;
const errors = @import("errors.zig");
const registry_mod = @import("registry.zig");
const Registry = registry_mod.Registry;
const ActorRef = registry_mod.ActorRef;
pub const BlimpError = errors.BlimpError;

pub const EvalError = builtins_mod.EvalError;

/// Tree-walking interpreter for Blimp expressions.
pub const Evaluator = struct {
    allocator: std.mem.Allocator,
    env: Environment,
    builtins: BuiltinRegistry,
    registry: Registry,
    last_error: ?BlimpError = null,
    source: []const u8 = "",
    actor_ctx: ?*ActorContext = null,
    msg_log: [64]MsgLogEntry = undefined,
    msg_log_count: u32 = 0,
    bubble_reason: ?*const Value = null,

    // Message log for canvas rays
    pub const MsgLogEntry = struct {
        target_id: u64,
        target_type: []const u8,
        message: []const u8,
    };

    pub const ActorContext = struct {
        entry: *registry_mod.ActorEntry,
        reply_value: ?*const Value = null,
        bubble_strategy: ?[]const u8 = null,
    };

    pub fn init(allocator: std.mem.Allocator) Evaluator {
        return .{
            .allocator = allocator,
            .env = Environment.init(allocator),
            .builtins = BuiltinRegistry.init(allocator),
            .registry = Registry.init(allocator),
        };
    }

    /// Set the source text for error reporting before eval.
    pub fn setSource(self: *Evaluator, src: []const u8) void {
        self.source = src;
        self.last_error = null;
    }

    /// Evaluate a single AST node to a runtime Value.
    pub fn eval(self: *Evaluator, node: ast.Node) EvalError!*const Value {
        switch (node.kind) {
            // Literals
            .integer_lit => |lit| {
                const v = self.allocator.create(Value) catch return error.OutOfMemory;
                v.* = Value{ .integer = lit.value };
                return v;
            },
            .float_lit => |lit| {
                const v = self.allocator.create(Value) catch return error.OutOfMemory;
                v.* = Value{ .float = lit.value };
                return v;
            },
            .string_lit => |lit| {
                // Strip surrounding quotes if present
                const raw = lit.value;
                const s = if (raw.len >= 2 and raw[0] == '"' and raw[raw.len - 1] == '"')
                    raw[1 .. raw.len - 1]
                else
                    raw;
                // Check for interpolation: #{expr}
                if (std.mem.indexOf(u8, s, "#{") != null) {
                    return self.evalStringInterp(s);
                }
                const v = self.allocator.create(Value) catch return error.OutOfMemory;
                v.* = Value{ .string = s };
                return v;
            },
            .atom_lit => |lit| {
                const v = self.allocator.create(Value) catch return error.OutOfMemory;
                v.* = Value{ .atom = lit.name };
                return v;
            },
            .bool_lit => |lit| {
                const v = self.allocator.create(Value) catch return error.OutOfMemory;
                v.* = Value{ .boolean = lit.value };
                return v;
            },
            .nil_lit => {
                const v = self.allocator.create(Value) catch return error.OutOfMemory;
                v.* = .nil;
                return v;
            },
            .hole => {
                const v = self.allocator.create(Value) catch return error.OutOfMemory;
                v.* = .hole;
                return v;
            },

            // Identifier
            .identifier => |id| {
                if (self.env.lookup(id.name)) |val| {
                    return val;
                }
                self.last_error = errors.undefinedVariable(id.name, self.source, &self.env, self.allocator);
                return error.UndefinedVariable;
            },

            // Assignment
            .assign_stmt => |assign| {
                const val = try self.eval(assign.value.*);
                self.env.define(assign.name, val);
                return val;
            },

            // Binary operations
            .binary_op => |op| return self.evalBinaryOp(op) catch |err| {
                if (self.last_error == null and err == error.TypeError) {
                    self.last_error = errors.typeMismatch(self.source);
                } else if (self.last_error == null and err == error.DivisionByZero) {
                    self.last_error = errors.divisionByZero(self.source);
                }
                return err;
            },

            // Unary operations
            .unary_op => |op| return self.evalUnaryOp(op),

            // Function call
            .func_call => |call| return self.evalFuncCall(call),

            // Pipe expression
            .pipe_expr => |pipe| return self.evalPipe(pipe),

            // List literal
            .list_lit => |list| return self.evalList(list),

            // Tuple literal
            .tuple_lit => |tuple| return self.evalTuple(tuple),

            // Map literal
            .map_lit => |map| return self.evalMap(map),

            // Dot access
            .dot_access => |da| return self.evalDotAccess(da),

            // Orelse
            .orelse_expr => |oe| return self.evalOrElse(oe),

            // Situation (pattern matching)
            .situation => |sit| return self.evalSituation(sit),

            // Case (same as situation for eval purposes)
            .case_expr => |ce| return self.evalSituation(ast.Node.Situation{
                .subject = ce.subject,
                .branches = ce.branches,
            }),

            // Actor definition
            .actor_def => |def| return self.evalActorDef(def),

            // State def is handled inside evalActorDef; standalone is an error
            .state_def => {
                self.last_error = errors.notSupportedInRepl("state", self.source);
                return error.NotSupported;
            },

            // Message handler is handled inside evalActorDef; standalone is an error
            .message_handler => {
                self.last_error = errors.notSupportedInRepl("on", self.source);
                return error.NotSupported;
            },

            // Become statement
            .become_stmt => |bs| return self.evalBecomeStmt(bs),

            // Reply statement
            .reply_stmt => |rs| return self.evalReplyStmt(rs),

            // Message send
            .message_send => |ms| return self.evalMessageSend(ms),

            // Spawn expression
            .spawn_expr => |se| return self.evalSpawnExpr(se),

            // Struct literal: %Counter{count: 42}
            .struct_lit => |sl| return self.evalStructLit(sl),

            // Anonymous function
            .fn_expr => |fe| return self.evalFnExpr(fe),

            // Calling an expression as a function
            .call_expr => |ce| return self.evalCallExpr(ce),

            // Named function definition
            .def_stmt => |ds| return self.evalDefStmt(ds),

            // Bubble (failure propagation)
            .bubble_stmt => |bs| return self.evalBubble(bs),

            // Range (not used directly, ranges are via range() builtin)
            .range_expr => return error.UnsupportedOperation,

            // For loop
            .for_expr => |fe| return self.evalForExpr(fe),

            // Spread: ...list, fn (map) and ..list, fn (each)
            .spread_map => |se| return self.evalSpreadMap(se),
            .spread_each => |se| return self.evalSpreadEach(se),

            // Self reference inside a handler
            .self_ref => return self.evalSelfRef(),
        }
    }

    fn evalActorDef(self: *Evaluator, def: ast.Node.ActorDef) EvalError!*const Value {
        // Collect state fields and handlers from the body
        var state_fields_list = std.ArrayList(Value.MapEntry){ .items = &.{}, .capacity = 0 };
        var handlers_list = std.ArrayList(Value.HandlerDef){ .items = &.{}, .capacity = 0 };

        for (def.body) |body_node| {
            switch (body_node.kind) {
                .state_def => |sd| {
                    for (sd.fields) |field| {
                        // Evaluate the default value
                        const val = self.eval(field.value) catch |err| return err;
                        state_fields_list.append(self.allocator, .{
                            .key = field.key,
                            .val = val,
                        }) catch return error.OutOfMemory;
                    }
                },
                .message_handler => |mh| {
                    handlers_list.append(self.allocator, .{
                        .name = mh.name,
                        .params = mh.params,
                        .guard = mh.guard,
                        .body = mh.body,
                        .bubble_strategy = mh.bubble_strategy,
                    }) catch return error.OutOfMemory;
                },
                else => {
                    // Ignore other body nodes (e.g. nested actors, not yet supported)
                },
            }
        }

        const default_state = state_fields_list.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
        const handlers = handlers_list.toOwnedSlice(self.allocator) catch return error.OutOfMemory;

        // Register the template in the registry
        self.registry.registerTemplate(def.name, default_state, handlers);

        // Bind the actor name as an atom in the environment (template marker)
        const v = self.allocator.create(Value) catch return error.OutOfMemory;
        v.* = Value{ .atom = def.name };

        self.env.define(def.name, v);

        return v;
    }

    fn evalSpawnExpr(self: *Evaluator, se: ast.Node.SpawnExpr) EvalError!*const Value {
        // Look up the template in the registry
        const template = self.registry.lookupTemplate(se.actor_name) orelse {
            self.last_error = errors.templateNotFound(se.actor_name, self.source);
            return error.UndefinedVariable;
        };

        // Evaluate override values
        var overrides_list = std.ArrayList(Value.MapEntry){ .items = &.{}, .capacity = 0 };
        for (se.overrides) |ov| {
            const val = try self.eval(ov.value);
            overrides_list.append(self.allocator, .{
                .key = ov.key,
                .val = val,
            }) catch return error.OutOfMemory;
        }
        const overrides = overrides_list.toOwnedSlice(self.allocator) catch return error.OutOfMemory;

        // Spawn a new instance
        const ref = self.registry.spawn(template, overrides);

        const v = self.allocator.create(Value) catch return error.OutOfMemory;
        v.* = Value{ .actor_ref = ref };
        return v;
    }

    fn evalForExpr(self: *Evaluator, fe: ast.Node.ForExpr) EvalError!*const Value {
        const iterable = try self.eval(fe.iterable.*);
        if (iterable.* != .list) return error.TypeError;

        var results: std.ArrayList(*const Value) = .{ .items = &.{}, .capacity = 0 };
        for (iterable.list) |item| {
            self.env.pushScope();
            self.env.define(fe.var_name, item);
            var last: *const Value = undefined;
            var has = false;
            for (fe.body) |stmt| {
                last = try self.eval(stmt);
                has = true;
            }
            self.env.popScope();
            if (has) results.append(self.allocator, last) catch return error.OutOfMemory;
        }
        const v = self.allocator.create(Value) catch return error.OutOfMemory;
        v.* = Value{ .list = results.toOwnedSlice(self.allocator) catch return error.OutOfMemory };
        return v;
    }

    fn evalSpreadMap(self: *Evaluator, se: ast.Node.SpreadExpr) EvalError!*const Value {
        const iterable = try self.eval(se.iterable.*);
        const func = try self.eval(se.func.*);
        if (iterable.* != .list) return error.TypeError;

        var results = self.allocator.alloc(*const Value, iterable.list.len) catch return error.OutOfMemory;
        for (iterable.list, 0..) |item, i| {
            results[i] = try self.callClosureWithValues(func, &.{item});
        }
        const v = self.allocator.create(Value) catch return error.OutOfMemory;
        v.* = Value{ .list = results };
        return v;
    }

    fn evalSpreadEach(self: *Evaluator, se: ast.Node.SpreadExpr) EvalError!*const Value {
        const iterable = try self.eval(se.iterable.*);
        const func = try self.eval(se.func.*);
        if (iterable.* != .list) return error.TypeError;

        for (iterable.list) |item| {
            _ = try self.callClosureWithValues(func, &.{item});
        }
        const v = self.allocator.create(Value) catch return error.OutOfMemory;
        v.* = Value{ .atom = "ok" };
        return v;
    }

    fn evalSelfRef(self: *Evaluator) EvalError!*const Value {
        if (self.actor_ctx) |ctx| {
            const v = self.allocator.create(Value) catch return error.OutOfMemory;
            v.* = Value{ .actor_ref = ctx.entry.ref };
            return v;
        }
        self.last_error = BlimpError{
            .title = "SELF OUTSIDE HANDLER",
            .source_line = self.source,
            .message = "`self` can only be used inside an actor handler.",
            .hint = null,
        };
        return error.NotSupported;
    }

    fn evalBubble(self: *Evaluator, bs: ast.Node.BubbleStmt) EvalError!*const Value {
        // Store the bubble reason if provided
        if (bs.reason) |reason_node| {
            const reason_val = try self.eval(reason_node.*);
            self.bubble_reason = reason_val;
        } else {
            self.bubble_reason = null;
        }

        // If we're in an actor handler with a bubble strategy, execute supervision
        if (self.actor_ctx) |ctx| {
            const actor_name = ctx.entry.ref.type_name;

            // Find the supervisor (parent) from dot notation
            // e.g., "Shop.Checkout" -> supervisor is "Shop"
            if (std.mem.lastIndexOf(u8, actor_name, ".")) |dot_idx| {
                const supervisor_name = actor_name[0..dot_idx];

                // Get the bubble strategy from the handler annotation
                const strategy = ctx.bubble_strategy orelse "SelfBubble";

                if (std.mem.eql(u8, strategy, "CascadeBubble")) {
                    // Restart all children of the supervisor
                    self.registry.restartChildren(supervisor_name);
                } else {
                    // SelfBubble: restart just this actor
                    self.registry.restartActor(ctx.entry.ref);
                }
            }
        }

        return error.Bubble;
    }

    fn evalStringInterp(self: *Evaluator, s: []const u8) EvalError!*const Value {
        var result: std.ArrayList(u8) = .{ .items = &.{}, .capacity = 0 };
        var i: usize = 0;
        while (i < s.len) {
            if (i + 1 < s.len and s[i] == '#' and s[i + 1] == '{') {
                // Find the closing }
                const start = i + 2;
                var depth: u32 = 1;
                var j = start;
                while (j < s.len and depth > 0) {
                    if (s[j] == '{') depth += 1;
                    if (s[j] == '}') depth -= 1;
                    if (depth > 0) j += 1;
                }
                if (depth != 0) return error.UnsupportedOperation;

                // Parse and evaluate the expression inside #{...}
                const expr_src = s[start..j];
                const P = @import("parser.zig").Parser;
                var parser = P.init(self.allocator, expr_src);
                const expr_node = parser.parseExpressionPublic() catch return error.UnsupportedOperation;
                const val = try self.eval(expr_node);

                // Format the value into the string
                var buf: [4096]u8 = undefined;
                var fbs = std.io.fixedBufferStream(&buf);
                val.format(fbs.writer());
                const formatted = fbs.getWritten();
                // Strip quotes from string values
                if (formatted.len >= 2 and formatted[0] == '"' and formatted[formatted.len - 1] == '"') {
                    result.appendSlice(self.allocator, formatted[1 .. formatted.len - 1]) catch return error.OutOfMemory;
                } else {
                    result.appendSlice(self.allocator, formatted) catch return error.OutOfMemory;
                }

                i = j + 1; // skip past }
            } else {
                result.append(self.allocator, s[i]) catch return error.OutOfMemory;
                i += 1;
            }
        }
        const v = self.allocator.create(Value) catch return error.OutOfMemory;
        v.* = Value{ .string = result.toOwnedSlice(self.allocator) catch return error.OutOfMemory };
        return v;
    }

    fn evalDefStmt(self: *Evaluator, ds: ast.Node.DefStmt) EvalError!*const Value {
        // def is sugar for: name = fn(params) do body end
        const bindings = self.env.allBindings(self.allocator);
        var captured = self.allocator.alloc(Value.CapturedBinding, bindings.len) catch return error.OutOfMemory;
        for (bindings, 0..) |b, i| {
            captured[i] = .{ .name = b.name, .val = b.val };
        }

        const v = self.allocator.create(Value) catch return error.OutOfMemory;
        v.* = Value{ .closure = .{
            .params = ds.params,
            .body = ds.body,
            .env = captured,
        } };

        self.env.define(ds.name, v);
        return v;
    }

    fn evalStructLit(self: *Evaluator, sl: ast.Node.StructLit) EvalError!*const Value {
        // %Counter{count: 42} = spawn Counter with overrides
        const template = self.registry.lookupTemplate(sl.type_name) orelse {
            self.last_error = errors.templateNotFound(sl.type_name, self.source);
            return error.UndefinedVariable;
        };

        var overrides_list = std.ArrayList(Value.MapEntry){ .items = &.{}, .capacity = 0 };
        for (sl.fields) |field| {
            const val = try self.eval(field.value);
            overrides_list.append(self.allocator, .{
                .key = field.key,
                .val = val,
            }) catch return error.OutOfMemory;
        }
        const overrides = overrides_list.toOwnedSlice(self.allocator) catch return error.OutOfMemory;

        const ref = self.registry.spawn(template, overrides);
        const v = self.allocator.create(Value) catch return error.OutOfMemory;
        v.* = Value{ .actor_ref = ref };
        return v;
    }

    fn evalFnExpr(self: *Evaluator, fe: ast.Node.FnExpr) EvalError!*const Value {
        // Capture the current environment bindings
        const bindings = self.env.allBindings(self.allocator);
        var captured = self.allocator.alloc(Value.CapturedBinding, bindings.len) catch return error.OutOfMemory;
        for (bindings, 0..) |b, i| {
            captured[i] = .{ .name = b.name, .val = b.val };
        }

        const v = self.allocator.create(Value) catch return error.OutOfMemory;
        v.* = Value{ .closure = .{
            .params = fe.params,
            .body = fe.body,
            .env = captured,
        } };
        return v;
    }

    fn evalCallExpr(self: *Evaluator, ce: ast.Node.CallExpr) EvalError!*const Value {
        const callee_val = try self.eval(ce.callee.*);
        return self.callClosure(callee_val, ce.args);
    }

    fn callClosure(self: *Evaluator, callee_val: *const Value, arg_nodes: []const ast.Node) EvalError!*const Value {
        switch (callee_val.*) {
            .closure => |c| {
                if (c.params.len != arg_nodes.len) {
                    self.last_error = errors.wrongArgCount("fn", c.params.len, arg_nodes.len, self.source);
                    return error.TypeError;
                }

                // Push a new scope with captured env + params
                self.env.pushScope();

                // Bind captured variables
                for (c.env) |binding| {
                    self.env.define(binding.name, binding.val);
                }

                // Bind parameters
                for (c.params, 0..) |param, i| {
                    const arg_val = self.eval(arg_nodes[i]) catch |err| {
                        self.env.popScope();
                        return err;
                    };
                    self.env.define(param, arg_val);
                }

                // Evaluate body
                var last_val: *const Value = undefined;
                var has_val = false;
                for (c.body) |stmt| {
                    last_val = self.eval(stmt) catch |err| {
                        self.env.popScope();
                        return err;
                    };
                    has_val = true;
                }

                self.env.popScope();

                if (has_val) return last_val;
                const nil_val = self.allocator.create(Value) catch return error.OutOfMemory;
                nil_val.* = Value.nil;
                return nil_val;
            },
            else => {
                self.last_error = errors.notCallable(self.source);
                return error.TypeError;
            },
        }
    }

    fn evalMessageSend(self: *Evaluator, ms: ast.Node.MessageSend) EvalError!*const Value {
        const target_val = try self.eval(ms.target.*);

        // Target must be an actor_ref
        switch (target_val.*) {
            .actor_ref => |ref| {
                // Log for canvas rays
                if (self.msg_log_count < 64) {
                    self.msg_log[self.msg_log_count] = .{
                        .target_id = ref.id,
                        .target_type = ref.type_name,
                        .message = ms.message,
                    };
                    self.msg_log_count += 1;
                }

                // Look up the instance in the registry
                const entry = self.registry.getInstance(ref) orelse {
                    self.last_error = errors.notAnActor(self.source);
                    return error.TypeError;
                };

                // Find a matching handler
                for (entry.handlers) |handler| {
                    if (!std.mem.eql(u8, handler.name, ms.message)) continue;

                    // Check argument count
                    if (handler.params.len != ms.args.len) {
                        self.last_error = errors.wrongArgCount(handler.name, handler.params.len, ms.args.len, self.source);
                        return error.TypeError;
                    }

                    // Evaluate the guard if present
                    if (handler.guard) |guard| {
                        // Push a scope for guard evaluation with params and state
                        self.env.pushScope();
                        defer self.env.popScope();

                        // Bind handler params
                        for (handler.params, 0..) |param, i| {
                            const arg_val = self.eval(ms.args[i]) catch |err| return err;
                            self.env.define(param.name, arg_val);
                        }

                        // Bind state fields
                        for (entry.state_fields) |field| {
                            self.env.define(field.key, field.val);
                        }

                        const guard_val = self.eval(guard.*) catch |err| return err;
                        if (!guard_val.truthy()) continue; // Guard failed, try next handler
                    }

                    // Execute the handler body
                    self.env.pushScope();

                    // Bind handler params
                    for (handler.params, 0..) |param, i| {
                        const arg_val = self.eval(ms.args[i]) catch |err| {
                            self.env.popScope();
                            return err;
                        };
                        self.env.define(param.name, arg_val);
                    }

                    // Bind state fields as variables
                    for (entry.state_fields) |field| {
                        self.env.define(field.key, field.val);
                    }

                    // Set actor context with bubble strategy from handler
                    var ctx = ActorContext{
                        .entry = entry,
                        .reply_value = null,
                        .bubble_strategy = handler.bubble_strategy,
                    };
                    const prev_ctx = self.actor_ctx;
                    self.actor_ctx = &ctx;

                    // Evaluate handler body
                    var last_val: *const Value = undefined;
                    var has_val = false;
                    for (handler.body) |stmt| {
                        last_val = self.eval(stmt) catch |err| {
                            self.actor_ctx = prev_ctx;
                            self.env.popScope();
                            return err;
                        };
                        has_val = true;
                    }

                    // Restore context
                    self.actor_ctx = prev_ctx;
                    self.env.popScope();

                    // Return reply value if set, otherwise last value or nil
                    if (ctx.reply_value) |rv| return rv;
                    if (has_val) return last_val;
                    const nil_val = self.allocator.create(Value) catch return error.OutOfMemory;
                    nil_val.* = .nil;
                    return nil_val;
                }

                // No handler matched
                self.last_error = errors.noMatchingHandler(ref.type_name, ms.message, self.source);
                return error.UndefinedVariable;
            },
            else => {
                self.last_error = errors.notAnActor(self.source);
                return error.TypeError;
            },
        }
    }

    fn evalBecomeStmt(self: *Evaluator, bs: ast.Node.BecomeStmt) EvalError!*const Value {
        const ctx = self.actor_ctx orelse {
            self.last_error = errors.becomeOutsideHandler(self.source);
            return error.NotSupported;
        };

        for (bs.fields) |field| {
            const new_val = try self.eval(field.value);

            // Find the matching state field and update it in place via the registry entry
            for (ctx.entry.state_fields) |*state_field| {
                if (std.mem.eql(u8, state_field.key, field.key)) {
                    state_field.val = new_val;
                    break;
                }
            }
        }

        // State is updated for the NEXT message. Scope bindings within this
        // handler body keep the old values (become is a snapshot transition).
        const result = self.allocator.create(Value) catch return error.OutOfMemory;
        result.* = .nil;
        return result;
    }

    fn evalReplyStmt(self: *Evaluator, rs: ast.Node.ReplyStmt) EvalError!*const Value {
        const ctx = self.actor_ctx orelse {
            self.last_error = errors.replyOutsideHandler(self.source);
            return error.NotSupported;
        };

        const val = try self.eval(rs.value.*);
        ctx.reply_value = val;
        return val;
    }

    fn evalBinaryOp(self: *Evaluator, op: ast.Node.BinaryOp) EvalError!*const Value {
        const left = try self.eval(op.left.*);
        const right = try self.eval(op.right.*);
        const result = self.allocator.create(Value) catch return error.OutOfMemory;

        switch (op.op) {
            .add => {
                switch (left.*) {
                    .integer => |a| switch (right.*) {
                        .integer => |b| {
                            result.* = Value{ .integer = a + b };
                            return result;
                        },
                        .float => |b| {
                            result.* = Value{ .float = @as(f64, @floatFromInt(a)) + b };
                            return result;
                        },
                        else => return error.TypeError,
                    },
                    .float => |a| switch (right.*) {
                        .integer => |b| {
                            result.* = Value{ .float = a + @as(f64, @floatFromInt(b)) };
                            return result;
                        },
                        .float => |b| {
                            result.* = Value{ .float = a + b };
                            return result;
                        },
                        else => return error.TypeError,
                    },
                    .string => |a| switch (right.*) {
                        .string => |b| {
                            const new_str = self.allocator.alloc(u8, a.len + b.len) catch return error.OutOfMemory;
                            @memcpy(new_str[0..a.len], a);
                            @memcpy(new_str[a.len..], b);
                            result.* = Value{ .string = new_str };
                            return result;
                        },
                        else => return error.TypeError,
                    },
                    else => return error.TypeError,
                }
            },
            .concat => {
                switch (left.*) {
                    .list => |a| switch (right.*) {
                        .list => |b| {
                            var items = self.allocator.alloc(*const Value, a.len + b.len) catch return error.OutOfMemory;
                            @memcpy(items[0..a.len], a);
                            @memcpy(items[a.len..], b);
                            result.* = Value{ .list = items };
                            return result;
                        },
                        else => return error.TypeError,
                    },
                    .string => |a| switch (right.*) {
                        .string => |b| {
                            const new_str = self.allocator.alloc(u8, a.len + b.len) catch return error.OutOfMemory;
                            @memcpy(new_str[0..a.len], a);
                            @memcpy(new_str[a.len..], b);
                            result.* = Value{ .string = new_str };
                            return result;
                        },
                        else => return error.TypeError,
                    },
                    else => return error.TypeError,
                }
            },
            .sub => return self.evalArithOp(left.*, right.*, result, .sub),
            .mul => return self.evalArithOp(left.*, right.*, result, .mul),
            .div => return self.evalArithOp(left.*, right.*, result, .div),
            .eq => {
                result.* = Value{ .boolean = left.eql(right.*) };
                return result;
            },
            .neq => {
                result.* = Value{ .boolean = !left.eql(right.*) };
                return result;
            },
            .lt => return self.evalCompareOp(left.*, right.*, result, .lt),
            .gt => return self.evalCompareOp(left.*, right.*, result, .gt),
            .lte => return self.evalCompareOp(left.*, right.*, result, .lte),
            .gte => return self.evalCompareOp(left.*, right.*, result, .gte),
            .and_op => {
                result.* = Value{ .boolean = left.truthy() and right.truthy() };
                return result;
            },
            .or_op => {
                result.* = Value{ .boolean = left.truthy() or right.truthy() };
                return result;
            },
        }
    }

    const ArithOp = enum { sub, mul, div };

    fn evalArithOp(self: *Evaluator, left: Value, right: Value, result: *Value, op: ArithOp) EvalError!*const Value {
        _ = self;
        switch (left) {
            .integer => |a| switch (right) {
                .integer => |b| {
                    result.* = switch (op) {
                        .sub => Value{ .integer = a - b },
                        .mul => Value{ .integer = a * b },
                        .div => blk: {
                            if (b == 0) return error.DivisionByZero;
                            break :blk Value{ .integer = @divTrunc(a, b) };
                        },
                    };
                    return result;
                },
                .float => |b| {
                    const fa: f64 = @floatFromInt(a);
                    result.* = switch (op) {
                        .sub => Value{ .float = fa - b },
                        .mul => Value{ .float = fa * b },
                        .div => blk: {
                            if (b == 0.0) return error.DivisionByZero;
                            break :blk Value{ .float = fa / b };
                        },
                    };
                    return result;
                },
                else => return error.TypeError,
            },
            .float => |a| switch (right) {
                .integer => |b| {
                    const fb: f64 = @floatFromInt(b);
                    result.* = switch (op) {
                        .sub => Value{ .float = a - fb },
                        .mul => Value{ .float = a * fb },
                        .div => blk: {
                            if (fb == 0.0) return error.DivisionByZero;
                            break :blk Value{ .float = a / fb };
                        },
                    };
                    return result;
                },
                .float => |b| {
                    result.* = switch (op) {
                        .sub => Value{ .float = a - b },
                        .mul => Value{ .float = a * b },
                        .div => blk: {
                            if (b == 0.0) return error.DivisionByZero;
                            break :blk Value{ .float = a / b };
                        },
                    };
                    return result;
                },
                else => return error.TypeError,
            },
            else => return error.TypeError,
        }
    }

    const CmpOp = enum { lt, gt, lte, gte };

    fn evalCompareOp(self: *Evaluator, left: Value, right: Value, result: *Value, op: CmpOp) EvalError!*const Value {
        _ = self;
        switch (left) {
            .integer => |a| switch (right) {
                .integer => |b| {
                    result.* = Value{
                        .boolean = switch (op) {
                            .lt => a < b,
                            .gt => a > b,
                            .lte => a <= b,
                            .gte => a >= b,
                        },
                    };
                    return result;
                },
                .float => |b| {
                    const fa: f64 = @floatFromInt(a);
                    result.* = Value{
                        .boolean = switch (op) {
                            .lt => fa < b,
                            .gt => fa > b,
                            .lte => fa <= b,
                            .gte => fa >= b,
                        },
                    };
                    return result;
                },
                else => return error.TypeError,
            },
            .float => |a| switch (right) {
                .integer => |b| {
                    const fb: f64 = @floatFromInt(b);
                    result.* = Value{
                        .boolean = switch (op) {
                            .lt => a < fb,
                            .gt => a > fb,
                            .lte => a <= fb,
                            .gte => a >= fb,
                        },
                    };
                    return result;
                },
                .float => |b| {
                    result.* = Value{
                        .boolean = switch (op) {
                            .lt => a < b,
                            .gt => a > b,
                            .lte => a <= b,
                            .gte => a >= b,
                        },
                    };
                    return result;
                },
                else => return error.TypeError,
            },
            else => return error.TypeError,
        }
    }

    fn evalUnaryOp(self: *Evaluator, op: ast.Node.UnaryOp) EvalError!*const Value {
        const operand = try self.eval(op.operand.*);
        const result = self.allocator.create(Value) catch return error.OutOfMemory;
        switch (op.op) {
            .negate => switch (operand.*) {
                .integer => |n| {
                    result.* = Value{ .integer = -n };
                    return result;
                },
                .float => |f| {
                    result.* = Value{ .float = -f };
                    return result;
                },
                else => return error.TypeError,
            },
            .not => {
                result.* = Value{ .boolean = !operand.truthy() };
                return result;
            },
        }
    }

    fn evalFuncCall(self: *Evaluator, call: ast.Node.FuncCall) EvalError!*const Value {
        // First check if the name refers to a closure in the environment
        if (self.env.lookup(call.name)) |val| {
            if (val.* == .closure) {
                return self.callClosure(val, call.args);
            }
        }

        // Higher-order builtins that need the evaluator to call closures
        if (std.mem.eql(u8, call.name, "map")) return self.builtinMap(call.args);
        if (std.mem.eql(u8, call.name, "filter")) return self.builtinFilter(call.args);
        if (std.mem.eql(u8, call.name, "reduce")) return self.builtinReduce(call.args);
        if (std.mem.eql(u8, call.name, "each")) return self.builtinEach(call.args);

        // Otherwise, look up the builtin
        const func = self.builtins.get(call.name) orelse {
            self.last_error = errors.unknownFunction(call.name, self.source);
            return error.UndefinedVariable;
        };

        // Evaluate arguments
        const args = self.allocator.alloc(*const Value, call.args.len) catch return error.OutOfMemory;
        for (call.args, 0..) |arg, i| {
            args[i] = try self.eval(arg);
        }

        return func(self.allocator, args);
    }

    // ── Higher-order builtins ─────────────────────────────

    /// map(list, fn(x) do ... end) -> new list
    fn builtinMap(self: *Evaluator, arg_nodes: []const ast.Node) EvalError!*const Value {
        if (arg_nodes.len != 2) return error.TypeError;
        const list_val = try self.eval(arg_nodes[0]);
        const fn_val = try self.eval(arg_nodes[1]);
        if (list_val.* != .list) return error.TypeError;

        const items = list_val.list;
        var results = self.allocator.alloc(*const Value, items.len) catch return error.OutOfMemory;
        for (items, 0..) |item, i| {
            // Create a single-element arg node that wraps the value
            results[i] = try self.callClosureWithValues(fn_val, &.{item});
        }
        const v = self.allocator.create(Value) catch return error.OutOfMemory;
        v.* = Value{ .list = results };
        return v;
    }

    /// filter(list, fn(x) do ... end) -> filtered list
    fn builtinFilter(self: *Evaluator, arg_nodes: []const ast.Node) EvalError!*const Value {
        if (arg_nodes.len != 2) return error.TypeError;
        const list_val = try self.eval(arg_nodes[0]);
        const fn_val = try self.eval(arg_nodes[1]);
        if (list_val.* != .list) return error.TypeError;

        var results: std.ArrayList(*const Value) = .{ .items = &.{}, .capacity = 0 };
        for (list_val.list) |item| {
            const result = try self.callClosureWithValues(fn_val, &.{item});
            if (result.truthy()) {
                results.append(self.allocator, item) catch return error.OutOfMemory;
            }
        }
        const v = self.allocator.create(Value) catch return error.OutOfMemory;
        v.* = Value{ .list = results.toOwnedSlice(self.allocator) catch return error.OutOfMemory };
        return v;
    }

    /// reduce(list, initial, fn(acc, x) do ... end) -> value
    fn builtinReduce(self: *Evaluator, arg_nodes: []const ast.Node) EvalError!*const Value {
        if (arg_nodes.len != 3) return error.TypeError;
        const list_val = try self.eval(arg_nodes[0]);
        var acc = try self.eval(arg_nodes[1]);
        const fn_val = try self.eval(arg_nodes[2]);
        if (list_val.* != .list) return error.TypeError;

        for (list_val.list) |item| {
            acc = try self.callClosureWithValues(fn_val, &.{ acc, item });
        }
        return acc;
    }

    /// each(list, fn(x) do ... end) -> :ok (side effects only)
    fn builtinEach(self: *Evaluator, arg_nodes: []const ast.Node) EvalError!*const Value {
        if (arg_nodes.len != 2) return error.TypeError;
        const list_val = try self.eval(arg_nodes[0]);
        const fn_val = try self.eval(arg_nodes[1]);
        if (list_val.* != .list) return error.TypeError;

        for (list_val.list) |item| {
            _ = try self.callClosureWithValues(fn_val, &.{item});
        }
        const v = self.allocator.create(Value) catch return error.OutOfMemory;
        v.* = Value{ .atom = "ok" };
        return v;
    }

    /// Call a closure with pre-evaluated Value arguments (not AST nodes)
    fn callClosureWithValues(self: *Evaluator, callee_val: *const Value, args: []const *const Value) EvalError!*const Value {
        switch (callee_val.*) {
            .closure => |c| {
                if (c.params.len != args.len) return error.TypeError;

                self.env.pushScope();

                // Bind captured variables
                for (c.env) |binding| {
                    self.env.define(binding.name, binding.val);
                }

                // Bind parameters
                for (c.params, 0..) |param, i| {
                    self.env.define(param, args[i]);
                }

                // Evaluate body
                var last_val: *const Value = undefined;
                var has_val = false;
                for (c.body) |stmt| {
                    last_val = self.eval(stmt) catch |err| {
                        self.env.popScope();
                        return err;
                    };
                    has_val = true;
                }

                self.env.popScope();

                if (has_val) return last_val;
                const nil_val = self.allocator.create(Value) catch return error.OutOfMemory;
                nil_val.* = Value.nil;
                return nil_val;
            },
            else => return error.TypeError,
        }
    }

    fn evalPipe(self: *Evaluator, pipe: ast.Node.PipeExpr) EvalError!*const Value {
        const left_val = try self.eval(pipe.left.*);

        // If right side is a func_call, check for hole args and substitute
        switch (pipe.right.kind) {
            .func_call => |call| {
                const func = self.builtins.get(call.name) orelse return error.UndefinedVariable;

                // Check if any arg is a hole -- if so, substitute left value
                var has_hole = false;
                for (call.args) |arg| {
                    if (arg.kind == .hole) {
                        has_hole = true;
                        break;
                    }
                }

                if (has_hole) {
                    const args = self.allocator.alloc(*const Value, call.args.len) catch return error.OutOfMemory;
                    for (call.args, 0..) |arg, i| {
                        if (arg.kind == .hole) {
                            args[i] = left_val;
                        } else {
                            args[i] = try self.eval(arg);
                        }
                    }
                    return func(self.allocator, args);
                } else {
                    // No hole -- pass left as first arg
                    const args = self.allocator.alloc(*const Value, call.args.len + 1) catch return error.OutOfMemory;
                    args[0] = left_val;
                    for (call.args, 0..) |arg, i| {
                        args[i + 1] = try self.eval(arg);
                    }
                    return func(self.allocator, args);
                }
            },
            .identifier => |id| {
                // Pipe into bare function name: items |> length
                // Check for closure first
                if (self.env.lookup(id.name)) |val| {
                    if (val.* == .closure) {
                        return self.callClosureWithValues(val, &.{left_val});
                    }
                }
                const func = self.builtins.get(id.name) orelse return error.UndefinedVariable;
                const args = self.allocator.alloc(*const Value, 1) catch return error.OutOfMemory;
                args[0] = left_val;
                return func(self.allocator, args);
            },
            .message_send => |ms| {
                // Pipe into message send: val |> actor <- :msg(_)
                // Substitute _ holes in the message args with the piped value
                const target_val = try self.eval(ms.target.*);
                switch (target_val.*) {
                    .actor_ref => |ref| {
                        const entry = self.registry.getInstance(ref) orelse return error.TypeError;

                        // Build args with hole substitution
                        var arg_vals: std.ArrayList(*const Value) = .{ .items = &.{}, .capacity = 0 };
                        for (ms.args) |arg| {
                            if (arg.kind == .hole) {
                                arg_vals.append(self.allocator, left_val) catch return error.OutOfMemory;
                            } else {
                                arg_vals.append(self.allocator, try self.eval(arg)) catch return error.OutOfMemory;
                            }
                        }

                        // If no args had holes, add piped value as first arg
                        if (ms.args.len == 0) {
                            // No-arg message: val |> actor <- :msg (piped value unused, just send)
                        }

                        // Find matching handler and execute
                        for (entry.handlers) |handler| {
                            if (!std.mem.eql(u8, handler.name, ms.message)) continue;
                            if (handler.params.len != arg_vals.items.len) continue;

                            self.env.pushScope();
                            for (handler.params, 0..) |param, i| {
                                self.env.define(param.name, arg_vals.items[i]);
                            }
                            for (entry.state_fields) |field| {
                                self.env.define(field.key, field.val);
                            }

                            var ctx = ActorContext{
                                .entry = entry,
                                .reply_value = null,
                                .bubble_strategy = handler.bubble_strategy,
                            };
                            const prev_ctx = self.actor_ctx;
                            self.actor_ctx = &ctx;

                            var last_val: *const Value = undefined;
                            var has_val = false;
                            for (handler.body) |stmt| {
                                last_val = self.eval(stmt) catch |err| {
                                    self.actor_ctx = prev_ctx;
                                    self.env.popScope();
                                    return err;
                                };
                                has_val = true;
                            }

                            self.actor_ctx = prev_ctx;
                            self.env.popScope();

                            if (ctx.reply_value) |rv| return rv;
                            if (has_val) return last_val;
                            const nil = self.allocator.create(Value) catch return error.OutOfMemory;
                            nil.* = .nil;
                            return nil;
                        }
                        return error.TypeError; // no matching handler
                    },
                    else => return error.TypeError,
                }
            },
            else => return error.UnsupportedOperation,
        }
    }

    fn evalList(self: *Evaluator, list: ast.Node.ListLit) EvalError!*const Value {
        const items = self.allocator.alloc(*const Value, list.elements.len) catch return error.OutOfMemory;
        for (list.elements, 0..) |elem, i| {
            items[i] = try self.eval(elem);
        }
        const result = self.allocator.create(Value) catch return error.OutOfMemory;
        result.* = Value{ .list = items };
        return result;
    }

    fn evalTuple(self: *Evaluator, tuple: ast.Node.TupleLit) EvalError!*const Value {
        const items = self.allocator.alloc(*const Value, tuple.elements.len) catch return error.OutOfMemory;
        for (tuple.elements, 0..) |elem, i| {
            items[i] = try self.eval(elem);
        }
        const result = self.allocator.create(Value) catch return error.OutOfMemory;
        result.* = Value{ .tuple = items };
        return result;
    }

    fn evalMap(self: *Evaluator, map: ast.Node.MapLit) EvalError!*const Value {
        const entries = self.allocator.alloc(Value.MapEntry, map.entries.len) catch return error.OutOfMemory;
        for (map.entries, 0..) |entry, i| {
            const val = try self.eval(entry.value);
            entries[i] = .{ .key = entry.key, .val = val };
        }
        const result = self.allocator.create(Value) catch return error.OutOfMemory;
        result.* = Value{ .map = entries };
        return result;
    }

    fn evalDotAccess(self: *Evaluator, da: ast.Node.DotAccess) EvalError!*const Value {
        const obj = try self.eval(da.object.*);
        switch (obj.*) {
            .map => |entries| {
                for (entries) |entry| {
                    if (std.mem.eql(u8, entry.key, da.field)) {
                        return entry.val;
                    }
                }
                // Field not found, return nil
                const result = self.allocator.create(Value) catch return error.OutOfMemory;
                result.* = .nil;
                return result;
            },
            else => return error.TypeError,
        }
    }

    fn evalOrElse(self: *Evaluator, oe: ast.Node.OrElseExpr) EvalError!*const Value {
        const try_val = self.eval(oe.try_expr.*) catch |err| {
            if (err == error.Bubble) {
                // Bubble caught by orelse - execute fallback
                return self.eval(oe.fallback.*);
            }
            return err;
        };
        switch (try_val.*) {
            .nil, .hole => return self.eval(oe.fallback.*),
            else => return try_val,
        }
    }

    fn evalSituation(self: *Evaluator, sit: ast.Node.Situation) EvalError!*const Value {
        const subject = try self.eval(sit.subject.*);

        for (sit.branches) |branch| {
            if (branch.pattern) |pattern| {
                // Try to match the pattern against the subject
                if (self.matchPattern(pattern.*, subject)) |bindings| {
                    // Push scope with bindings, evaluate body, pop
                    self.env.pushScope();
                    for (bindings) |b| {
                        self.env.define(b.name, b.val);
                    }
                    const result = self.evalBody(branch.body);
                    self.env.popScope();
                    return result;
                }
            } else {
                // Wildcard/hole branch -- always matches
                return self.evalBody(branch.body);
            }
        }

        // No branch matched, return nil
        const result = self.allocator.create(Value) catch return error.OutOfMemory;
        result.* = .nil;
        return result;
    }

    const PatternBinding = struct {
        name: []const u8,
        val: *const Value,
    };

    /// Try to match a pattern AST node against a runtime value.
    /// Returns bindings on success, null on failure.
    fn matchPattern(self: *Evaluator, pattern: ast.Node, subject: *const Value) ?[]const PatternBinding {
        switch (pattern.kind) {
            // Identifier: always matches, binds the value
            .identifier => |id| {
                var bindings = self.allocator.alloc(PatternBinding, 1) catch return null;
                bindings[0] = .{ .name = id.name, .val = subject };
                return bindings;
            },
            // Hole: always matches, no bindings
            .hole => return &.{},
            // Literals: match by value
            .integer_lit => |lit| {
                if (subject.* == .integer and subject.integer == lit.value) return &.{};
                return null;
            },
            .float_lit => |lit| {
                if (subject.* == .float and subject.float == lit.value) return &.{};
                return null;
            },
            .string_lit => |lit| {
                if (subject.* == .string and std.mem.eql(u8, subject.string, lit.value)) return &.{};
                return null;
            },
            .atom_lit => |lit| {
                if (subject.* == .atom and std.mem.eql(u8, subject.atom, lit.name)) return &.{};
                return null;
            },
            .bool_lit => |lit| {
                if (subject.* == .boolean and subject.boolean == lit.value) return &.{};
                return null;
            },
            .nil_lit => {
                if (subject.* == .nil) return &.{};
                return null;
            },
            // Map destructuring: %{key: var, key2: var2}
            .map_lit => |ml| {
                if (subject.* != .map) return null;
                var all_bindings: std.ArrayList(PatternBinding) = .{ .items = &.{}, .capacity = 0 };
                for (ml.entries) |entry| {
                    // Find the key in the subject map
                    var found = false;
                    for (subject.map) |map_entry| {
                        if (std.mem.eql(u8, map_entry.key, entry.key)) {
                            // Recursively match the value pattern
                            const sub_bindings = self.matchPattern(entry.value, map_entry.val) orelse return null;
                            for (sub_bindings) |b| {
                                all_bindings.append(self.allocator, b) catch return null;
                            }
                            found = true;
                            break;
                        }
                    }
                    if (!found) return null;
                }
                return all_bindings.toOwnedSlice(self.allocator) catch return null;
            },
            // List pattern: [head | tail] destructuring
            .list_lit => |ll| {
                if (subject.* != .list) return null;
                if (ll.tail != null) {
                    // [head | tail] pattern
                    if (subject.list.len == 0) return null;
                    var all_bindings: std.ArrayList(PatternBinding) = .{ .items = &.{}, .capacity = 0 };

                    // Match head elements
                    if (ll.elements.len > subject.list.len) return null;
                    for (ll.elements, 0..) |elem_pat, i| {
                        const sub = self.matchPattern(elem_pat, subject.list[i]) orelse return null;
                        for (sub) |b| all_bindings.append(self.allocator, b) catch return null;
                    }

                    // Bind tail
                    const tail_start = ll.elements.len;
                    const tail_items = subject.list[tail_start..];
                    const tail_val = self.allocator.create(Value) catch return null;
                    tail_val.* = Value{ .list = tail_items };
                    const tail_bindings = self.matchPattern(ll.tail.?.*, tail_val) orelse return null;
                    for (tail_bindings) |b| all_bindings.append(self.allocator, b) catch return null;

                    return all_bindings.toOwnedSlice(self.allocator) catch return null;
                } else {
                    // Fixed-length list pattern [a, b, c]
                    if (subject.list.len != ll.elements.len) return null;
                    var all_bindings: std.ArrayList(PatternBinding) = .{ .items = &.{}, .capacity = 0 };
                    for (ll.elements, 0..) |elem_pat, i| {
                        const sub = self.matchPattern(elem_pat, subject.list[i]) orelse return null;
                        for (sub) |b| all_bindings.append(self.allocator, b) catch return null;
                    }
                    return all_bindings.toOwnedSlice(self.allocator) catch return null;
                }
            },
            // Tuple pattern: {a, b}
            .tuple_lit => |tl| {
                if (subject.* != .tuple) return null;
                if (subject.tuple.len != tl.elements.len) return null;
                var all_bindings: std.ArrayList(PatternBinding) = .{ .items = &.{}, .capacity = 0 };
                for (tl.elements, 0..) |elem_pat, i| {
                    const sub = self.matchPattern(elem_pat, subject.tuple[i]) orelse return null;
                    for (sub) |b| all_bindings.append(self.allocator, b) catch return null;
                }
                return all_bindings.toOwnedSlice(self.allocator) catch return null;
            },
            else => {
                // For anything else, evaluate and compare
                const pat_val = self.eval(pattern) catch return null;
                if (subject.eql(pat_val.*)) return &.{};
                return null;
            },
        }
    }

    fn evalBody(self: *Evaluator, body: []const ast.Node) EvalError!*const Value {
        var last: *const Value = undefined;
        var has_val = false;
        for (body) |stmt| {
            last = try self.eval(stmt);
            has_val = true;
        }
        if (has_val) return last;
        const result = self.allocator.create(Value) catch return error.OutOfMemory;
        result.* = .nil;
        return result;
    }
};

// ============================================================
// Tests
// ============================================================

const Parser = @import("parser.zig").Parser;

fn evalExpr(allocator: std.mem.Allocator, source: []const u8) EvalError!*const Value {
    var parser = Parser.init(allocator, source);
    const node = parser.parseExpressionPublic() catch return error.UnsupportedOperation;
    var evaluator = Evaluator.init(allocator);
    return evaluator.eval(node);
}

fn evalStmt(allocator: std.mem.Allocator, evaluator: *Evaluator, source: []const u8) EvalError!*const Value {
    var parser = Parser.init(allocator, source);
    const node = parser.parseStatementPublic() catch return error.UnsupportedOperation;
    return evaluator.eval(node);
}

test "evaluate integer literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalExpr(arena.allocator(), "42");
    try std.testing.expect(result.eql(Value{ .integer = 42 }));
}

test "evaluate float literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalExpr(arena.allocator(), "3.14");
    try std.testing.expect(result.* == .float);
}

test "evaluate string literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalExpr(arena.allocator(), "\"hello\"");
    try std.testing.expect(result.eql(Value{ .string = "hello" }));
}

test "evaluate atom literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalExpr(arena.allocator(), ":ok");
    try std.testing.expect(result.eql(Value{ .atom = "ok" }));
}

test "evaluate boolean literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalExpr(arena.allocator(), "true");
    try std.testing.expect(result.eql(Value{ .boolean = true }));
}

test "evaluate nil literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalExpr(arena.allocator(), "nil");
    try std.testing.expect(result.eql(.nil));
}

test "evaluate arithmetic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalExpr(arena.allocator(), "1 + 2");
    try std.testing.expect(result.eql(Value{ .integer = 3 }));
}

test "evaluate arithmetic subtraction" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalExpr(arena.allocator(), "10 - 3");
    try std.testing.expect(result.eql(Value{ .integer = 7 }));
}

test "evaluate arithmetic multiplication" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalExpr(arena.allocator(), "3 * 4");
    try std.testing.expect(result.eql(Value{ .integer = 12 }));
}

test "evaluate arithmetic division" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalExpr(arena.allocator(), "10 / 3");
    try std.testing.expect(result.eql(Value{ .integer = 3 }));
}

test "evaluate comparison" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalExpr(arena.allocator(), "1 < 2");
    try std.testing.expect(result.eql(Value{ .boolean = true }));
}

test "evaluate equality" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalExpr(arena.allocator(), "42 == 42");
    try std.testing.expect(result.eql(Value{ .boolean = true }));
}

test "evaluate inequality" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalExpr(arena.allocator(), "1 != 2");
    try std.testing.expect(result.eql(Value{ .boolean = true }));
}

test "evaluate logical and" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalExpr(arena.allocator(), "true && false");
    try std.testing.expect(result.eql(Value{ .boolean = false }));
}

test "evaluate logical or" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalExpr(arena.allocator(), "true || false");
    try std.testing.expect(result.eql(Value{ .boolean = true }));
}

test "evaluate unary negate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalExpr(arena.allocator(), "-42");
    try std.testing.expect(result.eql(Value{ .integer = -42 }));
}

test "evaluate unary not" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalExpr(arena.allocator(), "!true");
    try std.testing.expect(result.eql(Value{ .boolean = false }));
}

test "evaluate list literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalExpr(arena.allocator(), "[1, 2, 3]");
    try std.testing.expect(result.* == .list);
    try std.testing.expectEqual(@as(usize, 3), result.list.len);
    try std.testing.expect(result.list[0].eql(Value{ .integer = 1 }));
    try std.testing.expect(result.list[2].eql(Value{ .integer = 3 }));
}

test "evaluate tuple literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalExpr(arena.allocator(), "{:ok, 42}");
    try std.testing.expect(result.* == .tuple);
    try std.testing.expectEqual(@as(usize, 2), result.tuple.len);
    try std.testing.expect(result.tuple[0].eql(Value{ .atom = "ok" }));
    try std.testing.expect(result.tuple[1].eql(Value{ .integer = 42 }));
}

test "evaluate variable assignment and lookup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var evaluator = Evaluator.init(alloc);
    const assign_result = try evalStmt(alloc, &evaluator, "x = 42");
    try std.testing.expect(assign_result.eql(Value{ .integer = 42 }));

    // Now look up x
    var parser2 = Parser.init(alloc, "x");
    const node2 = parser2.parseExpressionPublic() catch unreachable;
    const lookup_result = try evaluator.eval(node2);
    try std.testing.expect(lookup_result.eql(Value{ .integer = 42 }));
}

test "evaluate function call length" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalExpr(arena.allocator(), "length([1, 2, 3])");
    try std.testing.expect(result.eql(Value{ .integer = 3 }));
}

test "evaluate function call max" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalExpr(arena.allocator(), "max(5, 10)");
    try std.testing.expect(result.eql(Value{ .integer = 10 }));
}

test "evaluate function call min" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalExpr(arena.allocator(), "min(5, 10)");
    try std.testing.expect(result.eql(Value{ .integer = 5 }));
}

test "evaluate pipe expression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalExpr(arena.allocator(), "[1, 2, 3] |> length(_)");
    try std.testing.expect(result.eql(Value{ .integer = 3 }));
}

test "evaluate pipe into bare function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalExpr(arena.allocator(), "[1, 2, 3] |> length");
    try std.testing.expect(result.eql(Value{ .integer = 3 }));
}

test "evaluate pipe into reverse" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalExpr(arena.allocator(), "[1, 2, 3] |> reverse");
    try std.testing.expect(result.* == .list);
    try std.testing.expect(result.list[0].eql(Value{ .integer = 3 }));
    try std.testing.expect(result.list[2].eql(Value{ .integer = 1 }));
}

test "evaluate dot access on map" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var evaluator = Evaluator.init(alloc);
    _ = try evalStmt(alloc, &evaluator, "m = %{name: \"bob\", age: 30}");

    var parser = Parser.init(alloc, "m.name");
    const node = parser.parseExpressionPublic() catch unreachable;
    const result = try evaluator.eval(node);
    try std.testing.expect(result.eql(Value{ .string = "bob" }));
}

test "evaluate orelse with nil" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalExpr(arena.allocator(), "nil orelse 42");
    try std.testing.expect(result.eql(Value{ .integer = 42 }));
}

test "evaluate orelse with value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalExpr(arena.allocator(), "10 orelse 42");
    try std.testing.expect(result.eql(Value{ .integer = 10 }));
}

test "evaluate situation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var evaluator = Evaluator.init(alloc);
    _ = try evalStmt(alloc, &evaluator, "x = :ok");

    // Parse and eval a situation expression
    const source =
        \\situation x do
        \\  :ok -> 1
        \\  :error -> 2
        \\end
    ;
    var parser = Parser.init(alloc, source);
    // parseSituation is only accessible through parseActorBody, but situation is
    // also a top-level expression in our statement parser. Let's use parseStatementPublic.
    const node = parser.parseStatementPublic() catch unreachable;
    const result = try evaluator.eval(node);
    try std.testing.expect(result.eql(Value{ .integer = 1 }));
}

test "evaluate situation wildcard branch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var evaluator = Evaluator.init(alloc);
    _ = try evalStmt(alloc, &evaluator, "x = :unknown");

    const source =
        \\situation x do
        \\  :ok -> 1
        \\  _ -> 0
        \\end
    ;
    var parser = Parser.init(alloc, source);
    const node = parser.parseStatementPublic() catch unreachable;
    const result = try evaluator.eval(node);
    try std.testing.expect(result.eql(Value{ .integer = 0 }));
}

test "evaluate precedence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // 2 + 3 * 4 should be 2 + 12 = 14
    const result = try evalExpr(arena.allocator(), "2 + 3 * 4");
    try std.testing.expect(result.eql(Value{ .integer = 14 }));
}

test "evaluate division by zero" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = evalExpr(arena.allocator(), "10 / 0");
    try std.testing.expectError(error.DivisionByZero, result);
}

test "evaluate undefined variable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = evalExpr(arena.allocator(), "undefined_var");
    try std.testing.expectError(error.UndefinedVariable, result);
}

/// Evaluate a multi-line program (actor defs + statements), return the last value.
fn evalProgram(allocator: std.mem.Allocator, evaluator: *Evaluator, source: []const u8) EvalError!*const Value {
    var parser = Parser.init(allocator, source);
    const nodes = parser.parseFilePublic() catch return error.UnsupportedOperation;
    var last: *const Value = undefined;
    var has_val = false;
    for (nodes) |node| {
        last = try evaluator.eval(node);
        has_val = true;
    }
    if (has_val) return last;
    const nil_val = allocator.create(Value) catch return error.OutOfMemory;
    nil_val.* = .nil;
    return nil_val;
}

test "define actor template" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var evaluator = Evaluator.init(alloc);
    const result = try evalProgram(alloc, &evaluator,
        \\actor Counter do
        \\  state count: Int :: 0
        \\  on :increment do
        \\    become count: count + 1
        \\    reply count
        \\  end
        \\  on :get do
        \\    reply count
        \\  end
        \\end
    );

    // Should be an atom with the template name (not an instance)
    try std.testing.expect(result.* == .atom);
    try std.testing.expectEqualStrings("Counter", result.atom);

    // Template should exist in registry
    try std.testing.expect(evaluator.registry.lookupTemplate("Counter") != null);
}

test "spawn creates instance with ref" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var evaluator = Evaluator.init(alloc);
    _ = try evalProgram(alloc, &evaluator,
        \\actor Counter do
        \\  state count: Int :: 0
        \\  on :increment do
        \\    become count: count + 1
        \\    reply count + 1
        \\  end
        \\end
    );

    const result = try evalStmt(alloc, &evaluator, "c = spawn Counter");
    try std.testing.expect(result.* == .actor_ref);
    try std.testing.expectEqualStrings("Counter", result.actor_ref.type_name);
}

test "multiple spawns are independent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var evaluator = Evaluator.init(alloc);
    _ = try evalProgram(alloc, &evaluator,
        \\actor Counter do
        \\  state count: Int :: 0
        \\  on :increment do
        \\    become count: count + 1
        \\    reply count + 1
        \\  end
        \\end
    );

    _ = try evalStmt(alloc, &evaluator, "c1 = spawn Counter");
    _ = try evalStmt(alloc, &evaluator, "c2 = spawn Counter");

    // Increment c1
    const r1 = try evalStmt(alloc, &evaluator, "c1 <- :increment");
    try std.testing.expect(r1.eql(Value{ .integer = 1 }));

    // Increment c2 independently
    const r2 = try evalStmt(alloc, &evaluator, "c2 <- :increment");
    try std.testing.expect(r2.eql(Value{ .integer = 1 }));
}

test "spawn with state overrides" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var evaluator = Evaluator.init(alloc);
    _ = try evalProgram(alloc, &evaluator,
        \\actor Counter do
        \\  state count: Int :: 0
        \\  on :increment do
        \\    become count: count + 1
        \\    reply count + 1
        \\  end
        \\end
    );

    _ = try evalStmt(alloc, &evaluator, "c = spawn Counter, count: 10");
    const result = try evalStmt(alloc, &evaluator, "c <- :increment");
    try std.testing.expect(result.eql(Value{ .integer = 11 }));
}

test "send message to ref" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var evaluator = Evaluator.init(alloc);
    _ = try evalProgram(alloc, &evaluator,
        \\actor Counter do
        \\  state count: Int :: 0
        \\  on :increment do
        \\    become count: count + 1
        \\    reply count + 1
        \\  end
        \\end
    );

    _ = try evalStmt(alloc, &evaluator, "c = spawn Counter");
    const r1 = try evalStmt(alloc, &evaluator, "c <- :increment");
    try std.testing.expect(r1.eql(Value{ .integer = 1 }));
    const r2 = try evalStmt(alloc, &evaluator, "c <- :increment");
    try std.testing.expect(r2.eql(Value{ .integer = 2 }));
}

test "ref comparison" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var evaluator = Evaluator.init(alloc);
    _ = try evalProgram(alloc, &evaluator,
        \\actor Counter do
        \\  state count: Int :: 0
        \\  on :get do
        \\    reply count
        \\  end
        \\end
    );

    _ = try evalStmt(alloc, &evaluator, "c1 = spawn Counter");
    _ = try evalStmt(alloc, &evaluator, "c2 = spawn Counter");

    // c1 == c1 should be true
    const r1 = try evalStmt(alloc, &evaluator, "c1 == c1");
    try std.testing.expect(r1.eql(Value{ .boolean = true }));

    // c1 == c2 should be false
    const r2 = try evalStmt(alloc, &evaluator, "c1 == c2");
    try std.testing.expect(r2.eql(Value{ .boolean = false }));
}

test "actor state persists across messages" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var evaluator = Evaluator.init(alloc);
    _ = try evalProgram(alloc, &evaluator,
        \\actor Counter do
        \\  state count: Int :: 0
        \\  on :increment do
        \\    become count: count + 1
        \\    reply count + 1
        \\  end
        \\  on :get do
        \\    reply count
        \\  end
        \\end
    );

    _ = try evalStmt(alloc, &evaluator, "c = spawn Counter");

    // Send :increment twice
    _ = try evalStmt(alloc, &evaluator, "c <- :increment");
    _ = try evalStmt(alloc, &evaluator, "c <- :increment");

    // Send :get to check state -- become persists across messages
    const result = try evalStmt(alloc, &evaluator, "c <- :get");
    try std.testing.expect(result.eql(Value{ .integer = 2 }));
}

test "actor become updates state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var evaluator = Evaluator.init(alloc);
    _ = try evalProgram(alloc, &evaluator,
        \\actor Greeter do
        \\  state name: String :: "world"
        \\  on :set_name(n) do
        \\    become name: n
        \\    reply n
        \\  end
        \\  on :greet do
        \\    reply name
        \\  end
        \\end
    );

    _ = try evalStmt(alloc, &evaluator, "g = spawn Greeter");

    // reply n (the param) not name (which still has old scope value)
    const r1 = try evalStmt(alloc, &evaluator, "g <- :set_name(\"Alice\")");
    try std.testing.expect(r1.eql(Value{ .string = "Alice" }));

    const r2 = try evalStmt(alloc, &evaluator, "g <- :greet");
    try std.testing.expect(r2.eql(Value{ .string = "Alice" }));
}

test "message send with args" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var evaluator = Evaluator.init(alloc);
    _ = try evalProgram(alloc, &evaluator,
        \\actor Adder do
        \\  state total: Int :: 0
        \\  on :add(n) do
        \\    become total: total + n
        \\    reply total + n
        \\  end
        \\end
    );

    _ = try evalStmt(alloc, &evaluator, "a = spawn Adder");

    const r1 = try evalStmt(alloc, &evaluator, "a <- :add(5)");
    try std.testing.expect(r1.eql(Value{ .integer = 5 }));

    const r2 = try evalStmt(alloc, &evaluator, "a <- :add(3)");
    try std.testing.expect(r2.eql(Value{ .integer = 8 }));
}

test "unknown handler error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var evaluator = Evaluator.init(alloc);
    _ = try evalProgram(alloc, &evaluator,
        \\actor Simple do
        \\  state x: Int :: 0
        \\  on :get do
        \\    reply x
        \\  end
        \\end
    );

    _ = try evalStmt(alloc, &evaluator, "s = spawn Simple");

    const result = evalStmt(alloc, &evaluator, "s <- :nonexistent");
    try std.testing.expectError(error.UndefinedVariable, result);
}

test "handler with guard" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var evaluator = Evaluator.init(alloc);
    _ = try evalProgram(alloc, &evaluator,
        \\actor Account do
        \\  state balance: Int :: 100
        \\  on :withdraw(amount) when amount > 0 do
        \\    become balance: balance - amount
        \\    reply balance - amount
        \\  end
        \\  on :get_balance do
        \\    reply balance
        \\  end
        \\end
    );

    _ = try evalStmt(alloc, &evaluator, "acc = spawn Account");

    // Withdraw a valid amount
    const r1 = try evalStmt(alloc, &evaluator, "acc <- :withdraw(30)");
    try std.testing.expect(r1.eql(Value{ .integer = 70 }));

    // Check balance persisted
    const r2 = try evalStmt(alloc, &evaluator, "acc <- :get_balance");
    try std.testing.expect(r2.eql(Value{ .integer = 70 }));
}

test "spawn template not found error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var evaluator = Evaluator.init(alloc);
    const result = evalStmt(alloc, &evaluator, "c = spawn Nonexistent");
    try std.testing.expectError(error.UndefinedVariable, result);
}
