const std = @import("std");
const ast = @import("ast.zig");

const c = @cImport({
    @cInclude("llvm-c/Core.h");
    @cInclude("llvm-c/Target.h");
    @cInclude("llvm-c/TargetMachine.h");
    @cInclude("llvm-c/Analysis.h");
    @cInclude("llvm-c/Transforms/PassBuilder.h");
    @cInclude("llvm-c/BitWriter.h");
});

pub const CodegenError = error{
    UnsupportedNode,
    UndefinedVariable,
    LLVMError,
    VerificationFailed,
    TargetError,
    EmitError,
};

/// Variable scope: maps names to LLVM alloca pointers + type tags.
/// Uses a simple linear scan (fine for REPL-scale programs).
const Scope = struct {
    const Entry = struct {
        name: []const u8,
        alloca: c.LLVMValueRef,
        tag: Codegen.ValTag,
        llvm_type: c.LLVMTypeRef,
    };
    entries: std.ArrayList(Entry) = .empty,

    fn deinit(self: *Scope, allocator: std.mem.Allocator) void {
        self.entries.deinit(allocator);
    }

    fn put(self: *Scope, allocator: std.mem.Allocator, entry: Entry) void {
        for (self.entries.items) |*e| {
            if (std.mem.eql(u8, e.name, entry.name)) {
                e.* = entry;
                return;
            }
        }
        self.entries.append(allocator, entry) catch {};
    }

    fn get(self: *const Scope, name: []const u8) ?Entry {
        for (self.entries.items) |e| {
            if (std.mem.eql(u8, e.name, name)) return e;
        }
        return null;
    }
};

/// Atom intern table: maps atom names to sequential i32 IDs at compile time.
const AtomTable = struct {
    names: std.ArrayList([]const u8) = .empty,

    fn deinit(self: *AtomTable, allocator: std.mem.Allocator) void {
        self.names.deinit(allocator);
    }

    fn intern(self: *AtomTable, allocator: std.mem.Allocator, name: []const u8) u32 {
        for (self.names.items, 0..) |n, i| {
            if (std.mem.eql(u8, n, name)) return @intCast(i);
        }
        const id: u32 = @intCast(self.names.items.len);
        self.names.append(allocator, name) catch {};
        return id;
    }
};

/// Compiled actor descriptor -- tracks the LLVM artifacts for one actor type.
const ActorDescriptor = struct {
    name: []const u8,
    state_type: c.LLVMTypeRef, // LLVM struct type for state fields
    state_field_names: []const []const u8,
    state_field_count: u32,
    state_defaults: []const c.LLVMValueRef, // default values for each field
    state_default_tags: []const Codegen.ValTag,
    handler_fns: std.ArrayList(HandlerFn),

    const HandlerFn = struct {
        name: []const u8, // atom name of the message
        atom_id: u32,
        func: c.LLVMValueRef, // the compiled handler function
        param_count: u32,
    };
};

pub const Codegen = struct {
    context: c.LLVMContextRef,
    module: c.LLVMModuleRef,
    builder: c.LLVMBuilderRef,
    allocator: std.mem.Allocator,
    scope: Scope,
    atoms: AtomTable,
    actors: std.ArrayList(ActorDescriptor) = .empty,
    canvas_mode: bool = false,
    // Cached type refs
    i64_type: c.LLVMTypeRef,
    i32_type: c.LLVMTypeRef,
    f64_type: c.LLVMTypeRef,
    i1_type: c.LLVMTypeRef,
    void_type: c.LLVMTypeRef,
    ptr_type: c.LLVMTypeRef,
    handler_ret_type: c.LLVMTypeRef, // {i1, i64} -- matched flag + return value
    // Current function being built (needed for creating basic blocks)
    current_fn: ?c.LLVMValueRef = null,
    // When set, compileFuncCall marks calls to this name with musttail
    tail_call_target: ?[]const u8 = null,
    // Current actor context (set during handler compilation)
    current_actor: ?*ActorDescriptor = null,
    // Cached runtime function refs (lazily declared)
    print_int_fn: ?c.LLVMValueRef = null,
    print_float_fn: ?c.LLVMValueRef = null,
    print_bool_fn: ?c.LLVMValueRef = null,
    print_string_fn: ?c.LLVMValueRef = null,
    print_atom_fn: ?c.LLVMValueRef = null,
    print_nil_fn: ?c.LLVMValueRef = null,

    pub fn init(allocator: std.mem.Allocator, module_name: [*:0]const u8) Codegen {
        const ctx = c.LLVMContextCreate();
        const mod = c.LLVMModuleCreateWithNameInContext(module_name, ctx);
        const builder = c.LLVMCreateBuilderInContext(ctx);
        return .{
            .context = ctx,
            .module = mod,
            .builder = builder,
            .allocator = allocator,
            .scope = .{},
            .atoms = .{},
            .i64_type = c.LLVMInt64TypeInContext(ctx),
            .i32_type = c.LLVMInt32TypeInContext(ctx),
            .f64_type = c.LLVMDoubleTypeInContext(ctx),
            .i1_type = c.LLVMInt1TypeInContext(ctx),
            .void_type = c.LLVMVoidTypeInContext(ctx),
            .ptr_type = c.LLVMPointerTypeInContext(ctx, 0),
            .handler_ret_type = blk: {
                var members = [_]c.LLVMTypeRef{
                    c.LLVMInt1TypeInContext(ctx),
                    c.LLVMInt64TypeInContext(ctx),
                };
                break :blk c.LLVMStructTypeInContext(ctx, &members, 2, 0);
            },
        };
    }

    pub fn deinit(self: *Codegen) void {
        self.scope.deinit(self.allocator);
        self.atoms.deinit(self.allocator);
        for (self.actors.items) |*a| a.handler_fns.deinit(self.allocator);
        self.actors.deinit(self.allocator);
        c.LLVMDisposeBuilder(self.builder);
        c.LLVMDisposeModule(self.module);
        c.LLVMContextDispose(self.context);
    }

    // ── Runtime function declarations (lazy) ─────────────────

    fn getPrintInt(self: *Codegen) c.LLVMValueRef {
        if (self.print_int_fn) |f| return f;
        var params = [_]c.LLVMTypeRef{self.i64_type};
        const ft = c.LLVMFunctionType(self.void_type, &params, 1, 0);
        self.print_int_fn = c.LLVMAddFunction(self.module, "blimp_print_int", ft);
        return self.print_int_fn.?;
    }

    fn getPrintFloat(self: *Codegen) c.LLVMValueRef {
        if (self.print_float_fn) |f| return f;
        var params = [_]c.LLVMTypeRef{self.f64_type};
        const ft = c.LLVMFunctionType(self.void_type, &params, 1, 0);
        self.print_float_fn = c.LLVMAddFunction(self.module, "blimp_print_float", ft);
        return self.print_float_fn.?;
    }

    fn getPrintBool(self: *Codegen) c.LLVMValueRef {
        if (self.print_bool_fn) |f| return f;
        var params = [_]c.LLVMTypeRef{self.i64_type};
        const ft = c.LLVMFunctionType(self.void_type, &params, 1, 0);
        self.print_bool_fn = c.LLVMAddFunction(self.module, "blimp_print_bool", ft);
        return self.print_bool_fn.?;
    }

    fn getPrintString(self: *Codegen) c.LLVMValueRef {
        if (self.print_string_fn) |f| return f;
        var params = [_]c.LLVMTypeRef{self.ptr_type};
        const ft = c.LLVMFunctionType(self.void_type, &params, 1, 0);
        self.print_string_fn = c.LLVMAddFunction(self.module, "blimp_print_string", ft);
        return self.print_string_fn.?;
    }

    fn getPrintAtom(self: *Codegen) c.LLVMValueRef {
        if (self.print_atom_fn) |f| return f;
        var params = [_]c.LLVMTypeRef{self.ptr_type};
        const ft = c.LLVMFunctionType(self.void_type, &params, 1, 0);
        self.print_atom_fn = c.LLVMAddFunction(self.module, "blimp_print_atom", ft);
        return self.print_atom_fn.?;
    }

    fn getPrintNil(self: *Codegen) c.LLVMValueRef {
        if (self.print_nil_fn) |f| return f;
        const ft = c.LLVMFunctionType(self.void_type, &[_]c.LLVMTypeRef{}, 0, 0);
        self.print_nil_fn = c.LLVMAddFunction(self.module, "blimp_print_nil", ft);
        return self.print_nil_fn.?;
    }

    // ── Expression compilation ───────────────────────────────

    /// Tag enum to track what type an LLVM value represents.
    const ValTag = enum { int, float, boolean, string, atom, nil, actor_ref, tagged_val };

    const TaggedVal = struct {
        val: c.LLVMValueRef,
        tag: ValTag,
    };

    /// Compile an expression, returning the value and its type tag.
    pub fn compileExpr(self: *Codegen, node: ast.Node) CodegenError!TaggedVal {
        return switch (node.kind) {
            .integer_lit => |lit| .{ .val = c.LLVMConstInt(self.i64_type, @bitCast(lit.value), 1), .tag = .int },
            .float_lit => |lit| .{ .val = c.LLVMConstReal(self.f64_type, lit.value), .tag = .float },
            .bool_lit => |lit| .{
                .val = c.LLVMConstInt(self.i64_type, if (lit.value) 1 else 0, 0),
                .tag = .boolean,
            },
            .nil_lit => .{ .val = c.LLVMConstInt(self.i64_type, 0, 0), .tag = .nil },
            .string_lit => |lit| self.compileStringLit(lit),
            .atom_lit => |lit| self.compileAtomLit(lit),
            .identifier => |id| self.compileIdentifier(id),
            .binary_op => |op| self.compileBinaryOp(op),
            .unary_op => |op| self.compileUnaryOp(op),
            .assign_stmt => |stmt| self.compileAssign(stmt),
            .func_call => |call| self.compileFuncCall(call),
            .pipe_expr => |pipe| self.compilePipe(pipe),
            .situation => |sit| self.compileSituation(sit),
            .case_expr => |cas| self.compileCase(cas),
            .orelse_expr => |ore| self.compileOrelse(ore),
            .dot_access => |dot| self.compileDotAccess(dot),
            .actor_def => |def| self.compileActorDef(def),
            .spawn_expr => |spn| self.compileSpawn(spn),
            .struct_lit => |sl| self.compileStructLit(sl),
            .bubble_stmt => |bs| self.compileBubble(bs),
            .map_lit => |ml| self.compileMapLit(ml),
            .message_send => |msg| self.compileMessageSend(msg),
            .become_stmt => |bec| self.compileBecome(bec),
            .reply_stmt => |rep| self.compileReply(rep),
            .self_ref => self.compileSelfRef(),
            .for_expr => |fe| self.compileFor(fe),
            .spread_map => |se| self.compileSpreadMap(se),
            .spread_each => |se| self.compileSpreadEach(se),
            .list_lit => |ll| self.compileListLit(ll),
            .fn_expr => |fe| self.compileFnExpr(fe),
            .def_stmt => |ds| self.compileDef(ds),
            else => CodegenError.UnsupportedNode,
        };
    }

    /// Backward-compat: compile to raw LLVMValueRef (for tests).
    pub fn compileExpression(self: *Codegen, node: ast.Node) CodegenError!c.LLVMValueRef {
        const tv = try self.compileExpr(node);
        return tv.val;
    }

    /// Make a null-terminated C string from a Zig slice for LLVM names.
    fn zname(self: *Codegen, name: []const u8) [*:0]const u8 {
        const buf = self.allocator.allocSentinel(u8, name.len, 0) catch return "?";
        @memcpy(buf[0..name.len], name);
        return buf;
    }

    /// Coerce any value to i64 for uniform storage (state fields, handler returns).
    /// Pointers become ptrtoint, i32 atoms get zext, floats get bitcast.
    fn coerceToI64(self: *Codegen, tv: TaggedVal) c.LLVMValueRef {
        const val_type = c.LLVMTypeOf(tv.val);
        if (val_type == self.i64_type) return tv.val;
        const kind = c.LLVMGetTypeKind(val_type);
        if (kind == c.LLVMPointerTypeKind) {
            return c.LLVMBuildPtrToInt(self.builder, tv.val, self.i64_type, "ptr2i");
        }
        if (kind == c.LLVMIntegerTypeKind) {
            return c.LLVMBuildZExt(self.builder, tv.val, self.i64_type, "widen");
        }
        if (kind == c.LLVMDoubleTypeKind) {
            return c.LLVMBuildBitCast(self.builder, tv.val, self.i64_type, "f2i");
        }
        return tv.val;
    }

    /// Coerce an i64 back to the appropriate type for a given tag.
    fn coerceFromI64(self: *Codegen, val: c.LLVMValueRef, tag: ValTag) c.LLVMValueRef {
        return switch (tag) {
            .string, .tagged_val => c.LLVMBuildIntToPtr(self.builder, val, self.ptr_type, "i2ptr"),
            .atom => c.LLVMBuildTrunc(self.builder, val, self.i32_type, "trunc"),
            .float => c.LLVMBuildBitCast(self.builder, val, self.f64_type, "i2f"),
            else => val, // int, bool, nil, actor_ref are already i64
        };
    }

    /// Get the LLVM type for a given tag.
    fn llvmTypeForTag(self: *Codegen, tag: ValTag) c.LLVMTypeRef {
        return switch (tag) {
            .int, .boolean, .nil, .actor_ref => self.i64_type,
            .float => self.f64_type,
            .string, .tagged_val => self.ptr_type,
            .atom => self.i32_type,
        };
    }

    fn compileStringLit(self: *Codegen, lit: ast.Node.StringLit) TaggedVal {
        const raw = lit.value;
        const s = if (raw.len >= 2 and raw[0] == '"' and raw[raw.len - 1] == '"')
            raw[1 .. raw.len - 1]
        else
            raw;
        const global = c.LLVMBuildGlobalStringPtr(self.builder, self.zname(s), "str");
        return .{ .val = global, .tag = .string };
    }

    fn compileAtomLit(self: *Codegen, lit: ast.Node.AtomLit) TaggedVal {
        // Atoms are interned as i32 IDs for fast comparison.
        // The runtime uses a global string table to print them.
        const id = self.atoms.intern(self.allocator, lit.name);
        return .{
            .val = c.LLVMConstInt(self.i32_type, id, 0),
            .tag = .atom,
        };
    }

    fn compileIdentifier(self: *Codegen, id: ast.Node.Identifier) CodegenError!TaggedVal {
        const entry = self.scope.get(id.name) orelse return CodegenError.UndefinedVariable;
        const val = c.LLVMBuildLoad2(self.builder, entry.llvm_type, entry.alloca, self.zname(id.name));
        return .{ .val = val, .tag = entry.tag };
    }

    fn compileAssign(self: *Codegen, stmt: ast.Node.AssignStmt) CodegenError!TaggedVal {
        const rhs = try self.compileExpr(stmt.value.*);
        const lt = self.llvmTypeForTag(rhs.tag);
        const name_z = self.zname(stmt.name);

        if (self.scope.get(stmt.name)) |existing| {
            // Re-assign: if same type, just store. If different type, new alloca.
            if (existing.tag == rhs.tag) {
                _ = c.LLVMBuildStore(self.builder, rhs.val, existing.alloca);
            } else {
                const alloca = c.LLVMBuildAlloca(self.builder, lt, name_z);
                _ = c.LLVMBuildStore(self.builder, rhs.val, alloca);
                self.scope.put(self.allocator, .{
                    .name = stmt.name,
                    .alloca = alloca,
                    .tag = rhs.tag,
                    .llvm_type = lt,
                });
            }
        } else {
            const alloca = c.LLVMBuildAlloca(self.builder, lt, name_z);
            _ = c.LLVMBuildStore(self.builder, rhs.val, alloca);
            self.scope.put(self.allocator, .{
                .name = stmt.name,
                .alloca = alloca,
                .tag = rhs.tag,
                .llvm_type = lt,
            });
        }
        return rhs;
    }

    fn compileFuncCall(self: *Codegen, call: ast.Node.FuncCall) CodegenError!TaggedVal {
        const name = call.name;

        // max(a, b) and min(a, b) - inline as icmp+select
        if ((std.mem.eql(u8, name, "max") or std.mem.eql(u8, name, "min")) and call.args.len == 2) {
            const a = try self.compileExpr(call.args[0]);
            const b = try self.compileExpr(call.args[1]);
            const pred: c_uint = if (std.mem.eql(u8, name, "max")) c.LLVMIntSGT else c.LLVMIntSLT;
            const cmp = c.LLVMBuildICmp(self.builder, pred, a.val, b.val, "cmptmp");
            const val = c.LLVMBuildSelect(self.builder, cmp, a.val, b.val, self.zname(name));
            return .{ .val = val, .tag = .int };
        }

        // Generic: call extern blimp_<name>(args...)
        // For now, only support i64 args and return
        var arg_vals: [8]c.LLVMValueRef = undefined;
        var arg_types: [8]c.LLVMTypeRef = undefined;
        const n: u32 = @intCast(@min(call.args.len, 8));
        for (0..n) |i| {
            const arg = try self.compileExpr(call.args[i]);
            arg_vals[i] = arg.val;
            arg_types[i] = self.i64_type;
        }
        const ft = c.LLVMFunctionType(self.i64_type, &arg_types, n, 0);
        const extern_name = self.zname(name);
        var func = c.LLVMGetNamedFunction(self.module, extern_name);
        if (func == null) {
            func = c.LLVMAddFunction(self.module, extern_name, ft);
        }
        const val = c.LLVMBuildCall2(self.builder, ft, func, &arg_vals, n, "calltmp");
        // Mark as tail call if this is a recursive call to the current def
        if (self.tail_call_target) |target| {
            if (std.mem.eql(u8, name, target)) {
                c.LLVMSetTailCall(val, 1);
            }
        }
        return .{ .val = val, .tag = .int };
    }

    fn compilePipe(self: *Codegen, pipe: ast.Node.PipeExpr) CodegenError!TaggedVal {
        // Evaluate left side
        const left_val = try self.compileExpr(pipe.left.*);

        // Right side must be a func_call (with _ placeholder) or bare identifier
        const right = pipe.right.*;
        switch (right.kind) {
            .func_call => |call| {
                // Replace the hole/placeholder arg with left_val
                var arg_vals: [8]c.LLVMValueRef = undefined;
                var arg_types: [8]c.LLVMTypeRef = undefined;
                const n: u32 = @intCast(@min(call.args.len, 8));
                var used_placeholder = false;
                for (0..n) |i| {
                    if (call.args[i].kind == .hole) {
                        arg_vals[i] = left_val.val;
                        used_placeholder = true;
                    } else {
                        const arg = try self.compileExpr(call.args[i]);
                        arg_vals[i] = arg.val;
                    }
                    arg_types[i] = self.i64_type;
                }
                // If no placeholder found, insert left as first arg
                if (!used_placeholder) {
                    var shifted_vals: [8]c.LLVMValueRef = undefined;
                    var shifted_types: [8]c.LLVMTypeRef = undefined;
                    shifted_vals[0] = left_val.val;
                    shifted_types[0] = self.i64_type;
                    for (0..n) |i| {
                        shifted_vals[i + 1] = arg_vals[i];
                        shifted_types[i + 1] = arg_types[i];
                    }
                    const total: u32 = n + 1;
                    const ft = c.LLVMFunctionType(self.i64_type, &shifted_types, total, 0);
                    const func_name = self.zname(call.name);
                    var func = c.LLVMGetNamedFunction(self.module, func_name);
                    if (func == null) func = c.LLVMAddFunction(self.module, func_name, ft);
                    const val = c.LLVMBuildCall2(self.builder, ft, func, &shifted_vals, total, "pipetmp");
                    return .{ .val = val, .tag = .int };
                }

                const ft = c.LLVMFunctionType(self.i64_type, &arg_types, n, 0);
                const func_name = self.zname(call.name);
                var func = c.LLVMGetNamedFunction(self.module, func_name);
                if (func == null) func = c.LLVMAddFunction(self.module, func_name, ft);
                const val = c.LLVMBuildCall2(self.builder, ft, func, &arg_vals, n, "pipetmp");
                return .{ .val = val, .tag = .int };
            },
            .identifier => |id| {
                // Bare function: pipe as sole argument
                var arg_vals = [_]c.LLVMValueRef{left_val.val};
                var arg_types = [_]c.LLVMTypeRef{self.i64_type};
                const ft = c.LLVMFunctionType(self.i64_type, &arg_types, 1, 0);
                const func_name = self.zname(id.name);
                var func = c.LLVMGetNamedFunction(self.module, func_name);
                if (func == null) func = c.LLVMAddFunction(self.module, func_name, ft);
                const val = c.LLVMBuildCall2(self.builder, ft, func, &arg_vals, 1, "pipetmp");
                return .{ .val = val, .tag = .int };
            },
            else => return CodegenError.UnsupportedNode,
        }
    }

    fn compileBinaryOp(self: *Codegen, op: ast.Node.BinaryOp) CodegenError!TaggedVal {
        const lhs = try self.compileExpr(op.left.*);
        const rhs = try self.compileExpr(op.right.*);

        // Float path: if either operand is float, promote and use float ops
        if (lhs.tag == .float or rhs.tag == .float) {
            const fl = if (lhs.tag != .float)
                c.LLVMBuildSIToFP(self.builder, lhs.val, self.f64_type, "promo_l")
            else
                lhs.val;
            const fr = if (rhs.tag != .float)
                c.LLVMBuildSIToFP(self.builder, rhs.val, self.f64_type, "promo_r")
            else
                rhs.val;

            const val = switch (op.op) {
                .add => c.LLVMBuildFAdd(self.builder, fl, fr, "faddtmp"),
                .sub => c.LLVMBuildFSub(self.builder, fl, fr, "fsubtmp"),
                .mul => c.LLVMBuildFMul(self.builder, fl, fr, "fmultmp"),
                .div => c.LLVMBuildFDiv(self.builder, fl, fr, "fdivtmp"),
                .lt => blk: {
                    const cmp_val = c.LLVMBuildFCmp(self.builder, c.LLVMRealOLT, fl, fr, "flttmp");
                    break :blk c.LLVMBuildZExt(self.builder, cmp_val, self.i64_type, "fltext");
                },
                .gt => blk: {
                    const cmp_val = c.LLVMBuildFCmp(self.builder, c.LLVMRealOGT, fl, fr, "fgttmp");
                    break :blk c.LLVMBuildZExt(self.builder, cmp_val, self.i64_type, "fgtext");
                },
                .eq => blk: {
                    const cmp_val = c.LLVMBuildFCmp(self.builder, c.LLVMRealOEQ, fl, fr, "feqtmp");
                    break :blk c.LLVMBuildZExt(self.builder, cmp_val, self.i64_type, "feqext");
                },
                else => return CodegenError.UnsupportedNode,
            };
            // Comparisons return int, arithmetic returns float
            const tag: ValTag = switch (op.op) {
                .lt, .gt, .lte, .gte, .eq, .neq => .int,
                else => .float,
            };
            return .{ .val = val, .tag = tag };
        }

        // Integer path
        const val = switch (op.op) {
            .add => c.LLVMBuildAdd(self.builder, lhs.val, rhs.val, "addtmp"),
            .sub => c.LLVMBuildSub(self.builder, lhs.val, rhs.val, "subtmp"),
            .mul => c.LLVMBuildMul(self.builder, lhs.val, rhs.val, "multmp"),
            .div => c.LLVMBuildSDiv(self.builder, lhs.val, rhs.val, "divtmp"),
            .eq => blk: {
                const cmp_val = c.LLVMBuildICmp(self.builder, c.LLVMIntEQ, lhs.val, rhs.val, "eqtmp");
                break :blk c.LLVMBuildZExt(self.builder, cmp_val, self.i64_type, "eqext");
            },
            .neq => blk: {
                const cmp_val = c.LLVMBuildICmp(self.builder, c.LLVMIntNE, lhs.val, rhs.val, "neqtmp");
                break :blk c.LLVMBuildZExt(self.builder, cmp_val, self.i64_type, "neqext");
            },
            .lt => blk: {
                const cmp_val = c.LLVMBuildICmp(self.builder, c.LLVMIntSLT, lhs.val, rhs.val, "lttmp");
                break :blk c.LLVMBuildZExt(self.builder, cmp_val, self.i64_type, "ltext");
            },
            .gt => blk: {
                const cmp_val = c.LLVMBuildICmp(self.builder, c.LLVMIntSGT, lhs.val, rhs.val, "gttmp");
                break :blk c.LLVMBuildZExt(self.builder, cmp_val, self.i64_type, "gtext");
            },
            .lte => blk: {
                const cmp_val = c.LLVMBuildICmp(self.builder, c.LLVMIntSLE, lhs.val, rhs.val, "letmp");
                break :blk c.LLVMBuildZExt(self.builder, cmp_val, self.i64_type, "leext");
            },
            .gte => blk: {
                const cmp_val = c.LLVMBuildICmp(self.builder, c.LLVMIntSGE, lhs.val, rhs.val, "getmp");
                break :blk c.LLVMBuildZExt(self.builder, cmp_val, self.i64_type, "geext");
            },
            .and_op => c.LLVMBuildAnd(self.builder, lhs.val, rhs.val, "andtmp"),
            .or_op => c.LLVMBuildOr(self.builder, lhs.val, rhs.val, "ortmp"),
            .concat => return CodegenError.UnsupportedNode, // ++ needs tagged values
        };
        return .{ .val = val, .tag = .int };
    }

    fn compileUnaryOp(self: *Codegen, op: ast.Node.UnaryOp) CodegenError!TaggedVal {
        const operand = try self.compileExpr(op.operand.*);
        const val = switch (op.op) {
            .negate => if (operand.tag == .float)
                c.LLVMBuildFNeg(self.builder, operand.val, "fnegtmp")
            else
                c.LLVMBuildNeg(self.builder, operand.val, "negtmp"),
            .not => blk: {
                const zero = c.LLVMConstInt(self.i64_type, 0, 0);
                const cmp_val = c.LLVMBuildICmp(self.builder, c.LLVMIntEQ, operand.val, zero, "nottmp");
                break :blk c.LLVMBuildZExt(self.builder, cmp_val, self.i64_type, "notext");
            },
        };
        return .{ .val = val, .tag = operand.tag };
    }

    fn compileDotAccess(self: *Codegen, dot: ast.Node.DotAccess) CodegenError!TaggedVal {
        const obj = try self.compileExpr(dot.object.*);

        // Get the state pointer via runtime: blimp_get_state(actor_id) -> ptr
        const actor_id = c.LLVMBuildTrunc(self.builder, obj.val, self.i32_type, "dot_id");
        const get_state_fn = self.getRuntimeFn("blimp_get_state", &.{self.i32_type}, self.ptr_type);
        var gs_args = [_]c.LLVMValueRef{actor_id};
        var gs_pt = [_]c.LLVMTypeRef{self.i32_type};
        const state_ptr = c.LLVMBuildCall2(
            self.builder,
            c.LLVMFunctionType(self.ptr_type, &gs_pt, 1, 0),
            get_state_fn,
            &gs_args,
            1,
            "state_ptr",
        );

        // Search all actors for the field name
        for (self.actors.items) |actor| {
            for (0..actor.state_field_count) |i| {
                if (std.mem.eql(u8, actor.state_field_names[i], dot.field)) {
                    const idx: u32 = @intCast(i);
                    const gep = c.LLVMBuildStructGEP2(
                        self.builder,
                        actor.state_type,
                        state_ptr,
                        idx,
                        self.zname(dot.field),
                    );
                    const val = c.LLVMBuildLoad2(self.builder, self.i64_type, gep, self.zname(dot.field));
                    return .{ .val = val, .tag = .int };
                }
            }
        }
        return CodegenError.UnsupportedNode;
    }

    // ── Actor compilation ──────────────────────────────────

    fn findActor(self: *Codegen, name: []const u8) ?*ActorDescriptor {
        for (self.actors.items) |*a| {
            if (std.mem.eql(u8, a.name, name)) return a;
        }
        return null;
    }

    fn compileActorDef(self: *Codegen, def: ast.Node.ActorDef) CodegenError!TaggedVal {
        // Save and restore context
        const saved_fn = self.current_fn;
        const saved_scope = self.scope;
        const saved_actor = self.current_actor;
        defer {
            self.current_fn = saved_fn;
            self.scope = saved_scope;
            self.current_actor = saved_actor;
        }

        // 1. Collect state fields and their defaults
        var field_names: std.ArrayList([]const u8) = .empty;
        var field_types: std.ArrayList(c.LLVMTypeRef) = .empty;
        var field_defaults: std.ArrayList(c.LLVMValueRef) = .empty;
        var field_default_tags: std.ArrayList(ValTag) = .empty;

        // First pass: collect state fields
        for (def.body) |node| {
            if (node.kind == .state_def) {
                const state = node.kind.state_def;
                for (state.fields) |field| {
                    field_names.append(self.allocator, field.key) catch {};
                    field_types.append(self.allocator, self.i64_type) catch {}; // All fields stored as i64 for now
                    if (field.default_value) |dv| {
                        // We need to compile the default in main's context
                        const dv_result = self.compileExpr(dv.*) catch {
                            field_defaults.append(self.allocator, c.LLVMConstInt(self.i64_type, 0, 0)) catch {};
                            field_default_tags.append(self.allocator, .int) catch {};
                            continue;
                        };
                        field_defaults.append(self.allocator, dv_result.val) catch {};
                        field_default_tags.append(self.allocator, dv_result.tag) catch {};
                    } else {
                        field_defaults.append(self.allocator, c.LLVMConstInt(self.i64_type, 0, 0)) catch {};
                        field_default_tags.append(self.allocator, .int) catch {};
                    }
                }
            }
        }

        const field_count: u32 = @intCast(field_names.items.len);

        // Create state struct type: { i64, i64, ... } -- one i64 per field
        const state_struct = c.LLVMStructCreateNamed(self.context, self.zname(def.name));
        const member_types = self.allocator.alloc(c.LLVMTypeRef, field_count) catch return CodegenError.LLVMError;
        for (0..field_count) |i| {
            member_types[i] = self.i64_type;
        }
        c.LLVMStructSetBody(state_struct, member_types.ptr, field_count, 0);

        // Create actor descriptor
        const descriptor = ActorDescriptor{
            .name = def.name,
            .state_type = state_struct,
            .state_field_names = field_names.toOwnedSlice(self.allocator) catch return CodegenError.LLVMError,
            .state_field_count = field_count,
            .state_defaults = field_defaults.toOwnedSlice(self.allocator) catch return CodegenError.LLVMError,
            .state_default_tags = field_default_tags.toOwnedSlice(self.allocator) catch return CodegenError.LLVMError,
            .handler_fns = .empty,
        };

        self.actors.append(self.allocator, descriptor) catch {};
        // Get a stable pointer to the descriptor in the array
        const actor_ptr = &self.actors.items[self.actors.items.len - 1];
        self.current_actor = actor_ptr;

        // 2. Compile handler functions
        for (def.body) |node| {
            if (node.kind == .message_handler) {
                const handler = node.kind.message_handler;
                try self.compileHandler(def.name, handler, actor_ptr);
            }
        }

        // Register actor name as a variable (like the interpreter does)
        const atom_id = self.atoms.intern(self.allocator, def.name);
        const atom_val: TaggedVal = .{
            .val = c.LLVMConstInt(self.i32_type, atom_id, 0),
            .tag = .atom,
        };

        // Restore builder to main function, store the actor name
        if (saved_fn) |sfn| {
            const last_bb = c.LLVMGetLastBasicBlock(sfn);
            c.LLVMPositionBuilderAtEnd(self.builder, last_bb);
        }

        return atom_val;
    }

    fn compileHandler(
        self: *Codegen,
        actor_name: []const u8,
        handler: ast.Node.MessageHandler,
        actor_desc: *ActorDescriptor,
    ) CodegenError!void {
        // Handler signature: {i1, i64} @Actor_handler_name(ptr %actor_state, i64 %arg0, ...)
        // Returns {matched, value} -- matched=false means guard failed
        const param_count: u32 = @intCast(handler.params.len);
        const total_params = param_count + 1;

        const param_types = self.allocator.alloc(c.LLVMTypeRef, total_params) catch return CodegenError.LLVMError;
        param_types[0] = self.ptr_type;
        for (1..total_params) |i| {
            param_types[i] = self.i64_type;
        }

        const fn_type = c.LLVMFunctionType(self.handler_ret_type, param_types.ptr, total_params, 0);

        // Function name: Actor_handler_name
        const fn_name_buf = std.fmt.allocPrint(self.allocator, "{s}_handler_{s}", .{ actor_name, handler.name }) catch return CodegenError.LLVMError;
        const fn_name = self.zname(fn_name_buf);

        const func = c.LLVMAddFunction(self.module, fn_name, fn_type);
        self.current_fn = func;

        // Create entry block
        const entry = c.LLVMAppendBasicBlockInContext(self.context, func, "entry");
        c.LLVMPositionBuilderAtEnd(self.builder, entry);

        // Set up fresh scope with state fields and handler params
        self.scope = .{};

        // Bind state fields: load each from the state struct pointer (param 0)
        const state_ptr = c.LLVMGetParam(func, 0);
        for (0..actor_desc.state_field_count) |i| {
            const idx: u32 = @intCast(i);
            const field_name = actor_desc.state_field_names[i];
            const gep = c.LLVMBuildStructGEP2(self.builder, actor_desc.state_type, state_ptr, idx, self.zname(field_name));
            const loaded = c.LLVMBuildLoad2(self.builder, self.i64_type, gep, self.zname(field_name));

            // Store in local alloca so assignments work naturally
            const alloca = c.LLVMBuildAlloca(self.builder, self.i64_type, self.zname(field_name));
            _ = c.LLVMBuildStore(self.builder, loaded, alloca);
            self.scope.put(self.allocator, .{
                .name = field_name,
                .alloca = alloca,
                .tag = actor_desc.state_default_tags[i],
                .llvm_type = self.i64_type,
            });
        }

        // Bind handler params
        for (handler.params, 0..) |param, i| {
            const param_val = c.LLVMGetParam(func, @intCast(i + 1));
            const alloca = c.LLVMBuildAlloca(self.builder, self.i64_type, self.zname(param.name));
            _ = c.LLVMBuildStore(self.builder, param_val, alloca);
            self.scope.put(self.allocator, .{
                .name = param.name,
                .alloca = alloca,
                .tag = .int,
                .llvm_type = self.i64_type,
            });
        }

        // Guard: if present, evaluate and branch
        if (handler.guard) |guard_node| {
            const guard_val = try self.compileExpr(guard_node.*);
            const zero = c.LLVMConstInt(self.i64_type, 0, 0);
            const guard_bool = c.LLVMBuildICmp(self.builder, c.LLVMIntNE, guard_val.val, zero, "guard");

            const body_bb = c.LLVMAppendBasicBlockInContext(self.context, func, "body");
            const fail_bb = c.LLVMAppendBasicBlockInContext(self.context, func, "guard_fail");
            _ = c.LLVMBuildCondBr(self.builder, guard_bool, body_bb, fail_bb);

            // Guard fail: return {false, 0}
            c.LLVMPositionBuilderAtEnd(self.builder, fail_bb);
            _ = c.LLVMBuildRet(self.builder, self.makeHandlerRet(false, c.LLVMConstInt(self.i64_type, 0, 0)));

            c.LLVMPositionBuilderAtEnd(self.builder, body_bb);
        }

        // Compile handler body
        var last_val: TaggedVal = .{ .val = c.LLVMConstInt(self.i64_type, 0, 0), .tag = .nil };
        for (handler.body) |stmt| {
            last_val = try self.compileExpr(stmt);
        }

        // If body didn't end with reply (no terminator), add default return {true, 0}
        const current_bb = c.LLVMGetInsertBlock(self.builder);
        if (c.LLVMGetBasicBlockTerminator(current_bb) == null) {
            _ = c.LLVMBuildRet(self.builder, self.makeHandlerRet(true, c.LLVMConstInt(self.i64_type, 0, 0)));
        }

        // Register handler
        const atom_id = self.atoms.intern(self.allocator, handler.name);
        actor_desc.handler_fns.append(self.allocator, .{
            .name = handler.name,
            .atom_id = atom_id,
            .func = func,
            .param_count = param_count,
        }) catch {};
    }

    fn compileBecome(self: *Codegen, become: ast.Node.BecomeStmt) CodegenError!TaggedVal {
        // become writes new values to the actor state struct.
        // The state pointer is param 0 of the current handler function.
        const func = self.current_fn orelse return CodegenError.LLVMError;
        const actor = self.current_actor orelse return CodegenError.LLVMError;
        const state_ptr = c.LLVMGetParam(func, 0);

        for (become.fields) |field| {
            for (0..actor.state_field_count) |i| {
                if (std.mem.eql(u8, actor.state_field_names[i], field.key)) {
                    const new_val = try self.compileExpr(field.value);
                    const idx: u32 = @intCast(i);
                    const gep = c.LLVMBuildStructGEP2(
                        self.builder,
                        actor.state_type,
                        state_ptr,
                        idx,
                        self.zname(field.key),
                    );
                    // Coerce to i64 (handles ptr, i32, float -> i64)
                    const store_val = self.coerceToI64(new_val);
                    _ = c.LLVMBuildStore(self.builder, store_val, gep);
                    break;
                }
            }
        }
        return .{ .val = c.LLVMConstInt(self.i64_type, 0, 0), .tag = .nil };
    }

    fn compileReply(self: *Codegen, reply: ast.Node.ReplyStmt) CodegenError!TaggedVal {
        const val = try self.compileExpr(reply.value.*);
        // Coerce to i64 for the {i1, i64} handler return type
        const ret_val = self.coerceToI64(val);
        _ = c.LLVMBuildRet(self.builder, self.makeHandlerRet(true, ret_val));
        return val;
    }

    /// Build a {i1, i64} struct value for handler returns.
    fn makeHandlerRet(self: *Codegen, matched: bool, value: c.LLVMValueRef) c.LLVMValueRef {
        const flag = c.LLVMConstInt(self.i1_type, if (matched) 1 else 0, 0);
        const undef = c.LLVMGetUndef(self.handler_ret_type);
        const with_flag = c.LLVMBuildInsertValue(self.builder, undef, flag, 0, "ret_flag");
        return c.LLVMBuildInsertValue(self.builder, with_flag, value, 1, "ret_val");
    }

    fn compileSpawn(self: *Codegen, spn: ast.Node.SpawnExpr) CodegenError!TaggedVal {
        return self.compileSpawnInner(spn.actor_name, spn.overrides);
    }

    /// Shared spawn logic: allocate state, init fields, register actor, emit handler table.
    fn compileSpawnInner(self: *Codegen, actor_name: []const u8, overrides: []const ast.Node.KeyValue) CodegenError!TaggedVal {
        const actor = self.findActor(actor_name) orelse return CodegenError.UnsupportedNode;

        // Allocate state struct
        const size = c.LLVMSizeOf(actor.state_type);
        const malloc_fn = self.getMalloc();
        var malloc_args = [_]c.LLVMValueRef{size};
        var malloc_param_types = [_]c.LLVMTypeRef{self.i64_type};
        const malloc_ft = c.LLVMFunctionType(self.ptr_type, &malloc_param_types, 1, 0);
        const state_ptr = c.LLVMBuildCall2(self.builder, malloc_ft, malloc_fn, &malloc_args, 1, "state");

        // Initialize fields
        for (0..actor.state_field_count) |i| {
            const idx: u32 = @intCast(i);
            const field_name = actor.state_field_names[i];
            var value: TaggedVal = .{ .val = actor.state_defaults[i], .tag = actor.state_default_tags[i] };
            for (overrides) |ov| {
                if (std.mem.eql(u8, ov.key, field_name)) {
                    value = self.compileExpr(ov.value) catch break;
                    break;
                }
            }
            const gep = c.LLVMBuildStructGEP2(self.builder, actor.state_type, state_ptr, idx, self.zname(field_name));
            const store_val = self.coerceToI64(value);
            _ = c.LLVMBuildStore(self.builder, store_val, gep);
        }

        // Register with runtime: actor_id = blimp_register_actor(state_ptr)
        const reg_fn = self.getRuntimeFn("blimp_register_actor", &.{self.ptr_type}, self.i32_type);
        var reg_args = [_]c.LLVMValueRef{state_ptr};
        var reg_pt = [_]c.LLVMTypeRef{self.ptr_type};
        const actor_id = c.LLVMBuildCall2(
            self.builder,
            c.LLVMFunctionType(self.i32_type, &reg_pt, 1, 0),
            reg_fn,
            &reg_args,
            1,
            "actor_id",
        );

        // Build and register handler table
        self.emitHandlerTable(actor, actor_id);

        // Canvas: register actor type name and field info
        if (self.canvas_mode) {
            self.emitCanvasActorInfo(actor, actor_id);
        }

        // Return actor_id as i64
        const id_i64 = c.LLVMBuildZExt(self.builder, actor_id, self.i64_type, "id_wide");
        return .{ .val = id_i64, .tag = .actor_ref };
    }

    /// Emit canvas actor info: type name and field names.
    fn emitCanvasActorInfo(self: *Codegen, actor: *const ActorDescriptor, actor_id: c.LLVMValueRef) void {
        // blimp_set_actor_type(actor_id, "TypeName")
        const type_str = c.LLVMBuildGlobalStringPtr(self.builder, self.zname(actor.name), "type_name");
        const set_type_fn = self.getRuntimeFn("blimp_set_actor_type", &.{ self.i32_type, self.ptr_type }, self.void_type);
        var type_args = [_]c.LLVMValueRef{ actor_id, type_str };
        var type_pt = [_]c.LLVMTypeRef{ self.i32_type, self.ptr_type };
        _ = c.LLVMBuildCall2(self.builder, c.LLVMFunctionType(self.void_type, &type_pt, 2, 0), set_type_fn, &type_args, 2, "");

        // Build field name array as global and call blimp_set_actor_fields
        if (actor.state_field_count > 0) {
            // Create global string ptrs for each field name
            const field_ptrs = self.allocator.alloc(c.LLVMValueRef, actor.state_field_count) catch return;
            for (0..actor.state_field_count) |i| {
                field_ptrs[i] = c.LLVMBuildGlobalStringPtr(self.builder, self.zname(actor.state_field_names[i]), "fname");
            }
            // Create a global array of pointers
            const arr_type = c.LLVMArrayType2(self.ptr_type, actor.state_field_count);
            const arr_alloca = c.LLVMBuildAlloca(self.builder, arr_type, "field_names");
            for (0..actor.state_field_count) |i| {
                var indices = [_]c.LLVMValueRef{
                    c.LLVMConstInt(self.i32_type, 0, 0),
                    c.LLVMConstInt(self.i32_type, @intCast(i), 0),
                };
                const gep = c.LLVMBuildGEP2(self.builder, arr_type, arr_alloca, &indices, 2, "fn_ptr");
                _ = c.LLVMBuildStore(self.builder, field_ptrs[i], gep);
            }
            const set_fields_fn = self.getRuntimeFn("blimp_set_actor_fields", &.{ self.i32_type, self.ptr_type, self.i32_type }, self.void_type);
            var fields_args = [_]c.LLVMValueRef{ actor_id, arr_alloca, c.LLVMConstInt(self.i32_type, actor.state_field_count, 0) };
            var fields_pt = [_]c.LLVMTypeRef{ self.i32_type, self.ptr_type, self.i32_type };
            _ = c.LLVMBuildCall2(self.builder, c.LLVMFunctionType(self.void_type, &fields_pt, 3, 0), set_fields_fn, &fields_args, 3, "");
        }
    }

    /// Emit canvas enable + atom table registration at start of main.
    fn emitCanvasSetup(self: *Codegen) void {
        // blimp_canvas_enable()
        const enable_fn = self.getRuntimeFn("blimp_canvas_enable", &.{}, self.void_type);
        _ = c.LLVMBuildCall2(self.builder, c.LLVMFunctionType(self.void_type, &[_]c.LLVMTypeRef{}, 0, 0), enable_fn, &[_]c.LLVMValueRef{}, 0, "");

        // Register all atom names
        const set_atom_fn = self.getRuntimeFn("blimp_set_atom_name", &.{ self.i32_type, self.ptr_type }, self.void_type);
        for (self.atoms.names.items, 0..) |name, i| {
            const str = c.LLVMBuildGlobalStringPtr(self.builder, self.zname(name), "atom");
            var args = [_]c.LLVMValueRef{ c.LLVMConstInt(self.i32_type, @intCast(i), 0), str };
            var pt = [_]c.LLVMTypeRef{ self.i32_type, self.ptr_type };
            _ = c.LLVMBuildCall2(self.builder, c.LLVMFunctionType(self.void_type, &pt, 2, 0), set_atom_fn, &args, 2, "");
        }
    }

    /// Emit canvas dump call at end of main.
    fn emitCanvasDump(self: *Codegen, path: [*:0]const u8) void {
        const dump_fn = self.getRuntimeFn("blimp_canvas_dump", &.{self.ptr_type}, self.void_type);
        const path_str = c.LLVMBuildGlobalStringPtr(self.builder, path, "canvas_path");
        var args = [_]c.LLVMValueRef{path_str};
        var pt = [_]c.LLVMTypeRef{self.ptr_type};
        _ = c.LLVMBuildCall2(self.builder, c.LLVMFunctionType(self.void_type, &pt, 1, 0), dump_fn, &args, 1, "");
    }

    /// %Actor{field: val, ...} -- sugar for spawn with overrides.
    fn compileStructLit(self: *Codegen, sl: ast.Node.StructLit) CodegenError!TaggedVal {
        // Reuse compileSpawn by constructing the equivalent SpawnExpr fields
        return self.compileSpawnInner(sl.type_name, sl.fields);
    }

    /// Bubble: in compiled code, returns {matched=true, 0} and the runtime
    /// treats the handler as "no useful reply". For now, bubble is a no-op return.
    /// TODO: propagate bubble reason through an error channel.
    fn compileBubble(self: *Codegen, bs: ast.Node.BubbleStmt) CodegenError!TaggedVal {
        // Compile the reason expression (if any) for side effects, but discard
        if (bs.reason) |reason| {
            _ = try self.compileExpr(reason.*);
        }
        // Return {matched=true, 0} -- signals "handled but no value"
        _ = c.LLVMBuildRet(self.builder, self.makeHandlerRet(true, c.LLVMConstInt(self.i64_type, 0, 0)));
        return .{ .val = c.LLVMConstInt(self.i64_type, 0, 0), .tag = .nil };
    }

    /// Compile map literal: %{key: val, ...} -> BlimpVal*
    fn compileMapLit(self: *Codegen, ml: ast.Node.MapLit) CodegenError!TaggedVal {
        const entry_count: u32 = @intCast(ml.entries.len);

        // blimp_val_map(initial_cap) -> ptr
        const make_fn = self.getRuntimeFn("blimp_val_map", &.{self.i32_type}, self.ptr_type);
        var make_args = [_]c.LLVMValueRef{c.LLVMConstInt(self.i32_type, entry_count, 0)};
        var make_pt = [_]c.LLVMTypeRef{self.i32_type};
        const map_ptr = c.LLVMBuildCall2(
            self.builder,
            c.LLVMFunctionType(self.ptr_type, &make_pt, 1, 0),
            make_fn,
            &make_args,
            1,
            "map",
        );

        // blimp_map_put(map, key, val)
        const put_fn = self.getRuntimeFn("blimp_map_put", &.{ self.ptr_type, self.ptr_type, self.ptr_type }, self.void_type);

        for (ml.entries) |entry| {
            // Key is a string
            const key_str = c.LLVMBuildGlobalStringPtr(self.builder, self.zname(entry.key), "key");

            // Value -- wrap it as a BlimpVal*
            const val_tv = try self.compileExpr(entry.value);
            const val_ptr = self.wrapAsBlimpVal(val_tv);

            var put_args = [_]c.LLVMValueRef{ map_ptr, key_str, val_ptr };
            var put_pt = [_]c.LLVMTypeRef{ self.ptr_type, self.ptr_type, self.ptr_type };
            _ = c.LLVMBuildCall2(
                self.builder,
                c.LLVMFunctionType(self.void_type, &put_pt, 3, 0),
                put_fn,
                &put_args,
                3,
                "",
            );
        }

        return .{ .val = map_ptr, .tag = .tagged_val };
    }

    /// Wrap a tagged value as a BlimpVal* by calling the appropriate runtime constructor.
    fn wrapAsBlimpVal(self: *Codegen, tv: TaggedVal) c.LLVMValueRef {
        return switch (tv.tag) {
            .int => blk: {
                const f = self.getRuntimeFn("blimp_val_int", &.{self.i64_type}, self.ptr_type);
                var args = [_]c.LLVMValueRef{tv.val};
                var pt = [_]c.LLVMTypeRef{self.i64_type};
                break :blk c.LLVMBuildCall2(self.builder, c.LLVMFunctionType(self.ptr_type, &pt, 1, 0), f, &args, 1, "boxed");
            },
            .float => blk: {
                const f = self.getRuntimeFn("blimp_val_float", &.{self.f64_type}, self.ptr_type);
                var args = [_]c.LLVMValueRef{tv.val};
                var pt = [_]c.LLVMTypeRef{self.f64_type};
                break :blk c.LLVMBuildCall2(self.builder, c.LLVMFunctionType(self.ptr_type, &pt, 1, 0), f, &args, 1, "boxed");
            },
            .string => blk: {
                const f = self.getRuntimeFn("blimp_val_string", &.{self.ptr_type}, self.ptr_type);
                // String may be stored as i64 (ptrtoint) in state fields -- convert back to ptr
                var str_val = tv.val;
                if (c.LLVMGetTypeKind(c.LLVMTypeOf(str_val)) == c.LLVMIntegerTypeKind) {
                    str_val = c.LLVMBuildIntToPtr(self.builder, str_val, self.ptr_type, "i2str");
                }
                var args = [_]c.LLVMValueRef{str_val};
                var pt = [_]c.LLVMTypeRef{self.ptr_type};
                break :blk c.LLVMBuildCall2(self.builder, c.LLVMFunctionType(self.ptr_type, &pt, 1, 0), f, &args, 1, "boxed");
            },
            .atom => blk: {
                const f = self.getRuntimeFn("blimp_val_atom", &.{self.i32_type}, self.ptr_type);
                var args = [_]c.LLVMValueRef{tv.val};
                var pt = [_]c.LLVMTypeRef{self.i32_type};
                break :blk c.LLVMBuildCall2(self.builder, c.LLVMFunctionType(self.ptr_type, &pt, 1, 0), f, &args, 1, "boxed");
            },
            .boolean => blk: {
                const f = self.getRuntimeFn("blimp_val_bool", &.{self.i32_type}, self.ptr_type);
                const b32 = c.LLVMBuildTrunc(self.builder, tv.val, self.i32_type, "b32");
                var args = [_]c.LLVMValueRef{b32};
                var pt = [_]c.LLVMTypeRef{self.i32_type};
                break :blk c.LLVMBuildCall2(self.builder, c.LLVMFunctionType(self.ptr_type, &pt, 1, 0), f, &args, 1, "boxed");
            },
            .tagged_val => tv.val, // Already a BlimpVal*
            .nil, .actor_ref => blk: {
                const f = self.getRuntimeFn("blimp_val_nil", &.{}, self.ptr_type);
                break :blk c.LLVMBuildCall2(self.builder, c.LLVMFunctionType(self.ptr_type, &[_]c.LLVMTypeRef{}, 0, 0), f, &[_]c.LLVMValueRef{}, 0, "boxed");
            },
        };
    }

    // ── New feature codegen (tagged value path) ──────────

    fn compileSelfRef(self: *Codegen) CodegenError!TaggedVal {
        // Get current actor count - 1 (the last spawned actor in current handler context)
        const count_fn = self.getRuntimeFn("blimp_actor_count", &.{}, self.i32_type);
        const count = c.LLVMBuildCall2(self.builder, c.LLVMFunctionType(self.i32_type, null, 0, 0), count_fn, null, 0, "acount");
        const one = c.LLVMConstInt(self.i32_type, 1, 0);
        const id = c.LLVMBuildSub(self.builder, count, one, "self_id");
        // Widen to i64 for actor_ref
        const id64 = c.LLVMBuildZExt(self.builder, id, self.i64_type, "self_id64");
        return .{ .val = id64, .tag = .actor_ref };
    }

    fn compileFor(self: *Codegen, fe: ast.Node.ForExpr) CodegenError!TaggedVal {
        // Compile iterable
        const list_tv = try self.compileExpr(fe.iterable.*);

        // Create runtime list for results
        const make_list_fn = self.getRuntimeFn("blimp_val_list", &.{self.i32_type}, self.ptr_type);
        const init_cap = c.LLVMConstInt(self.i32_type, 16, 0);
        var make_args = [_]c.LLVMValueRef{init_cap};
        var make_param_types = [_]c.LLVMTypeRef{self.i32_type};
        const result_list = c.LLVMBuildCall2(self.builder,
            c.LLVMFunctionType(self.ptr_type, &make_param_types, 1, 0),
            make_list_fn, &make_args, 1, "result_list");

        // Get list length
        const len_fn = self.getRuntimeFn("blimp_list_len", &.{self.ptr_type}, self.i32_type);
        var len_args = [_]c.LLVMValueRef{list_tv.val};
        var len_param_types = [_]c.LLVMTypeRef{self.ptr_type};
        const len = c.LLVMBuildCall2(self.builder,
            c.LLVMFunctionType(self.i32_type, &len_param_types, 1, 0),
            len_fn, &len_args, 1, "list_len");

        // Loop: for i = 0; i < len; i++
        const cur_fn = self.current_fn orelse return CodegenError.LLVMError;
        const loop_bb = c.LLVMAppendBasicBlock(cur_fn, "for_loop");
        const body_bb = c.LLVMAppendBasicBlock(cur_fn, "for_body");
        const end_bb = c.LLVMAppendBasicBlock(cur_fn, "for_end");

        // i = 0
        const i_alloca = c.LLVMBuildAlloca(self.builder, self.i32_type, "i");
        _ = c.LLVMBuildStore(self.builder, c.LLVMConstInt(self.i32_type, 0, 0), i_alloca);
        _ = c.LLVMBuildBr(self.builder, loop_bb);

        // Loop header: check i < len
        c.LLVMPositionBuilderAtEnd(self.builder, loop_bb);
        const i_val = c.LLVMBuildLoad2(self.builder, self.i32_type, i_alloca, "i");
        const cond = c.LLVMBuildICmp(self.builder, c.LLVMIntSLT, i_val, len, "cmp");
        _ = c.LLVMBuildCondBr(self.builder, cond, body_bb, end_bb);

        // Body: get element, bind var, compile body, push result
        c.LLVMPositionBuilderAtEnd(self.builder, body_bb);
        const get_fn = self.getRuntimeFn("blimp_list_get", &.{ self.ptr_type, self.i32_type }, self.ptr_type);
        var get_args = [_]c.LLVMValueRef{ list_tv.val, i_val };
        var get_param_types = [_]c.LLVMTypeRef{ self.ptr_type, self.i32_type };
        const elem = c.LLVMBuildCall2(self.builder,
            c.LLVMFunctionType(self.ptr_type, &get_param_types, 2, 0),
            get_fn, &get_args, 2, "elem");

        // Unwrap the BlimpVal* to i64 for use in expressions
        const unwrap_fn = self.getRuntimeFn("blimp_val_to_int", &.{self.ptr_type}, self.i64_type);
        var unwrap_args = [_]c.LLVMValueRef{elem};
        var unwrap_pt = [_]c.LLVMTypeRef{self.ptr_type};
        const unwrapped = c.LLVMBuildCall2(self.builder,
            c.LLVMFunctionType(self.i64_type, &unwrap_pt, 1, 0),
            unwrap_fn, &unwrap_args, 1, "unwrapped");

        // Bind loop variable as i64
        const var_alloca = c.LLVMBuildAlloca(self.builder, self.i64_type, self.zname(fe.var_name));
        _ = c.LLVMBuildStore(self.builder, unwrapped, var_alloca);
        self.scope.put(self.allocator, .{ .name = fe.var_name, .alloca = var_alloca, .tag = .int, .llvm_type = self.i64_type });

        // Compile body
        var last_tv: TaggedVal = .{ .val = c.LLVMConstInt(self.i64_type, 0, 0), .tag = .nil };
        for (fe.body) |stmt| {
            last_tv = try self.compileExpr(stmt);
        }

        // Wrap result as BlimpVal and push to result list
        const wrap_fn = self.getRuntimeFn("blimp_val_int", &.{self.i64_type}, self.ptr_type);
        var wrap_args = [_]c.LLVMValueRef{last_tv.val};
        var wrap_param_types = [_]c.LLVMTypeRef{self.i64_type};
        const wrapped = c.LLVMBuildCall2(self.builder,
            c.LLVMFunctionType(self.ptr_type, &wrap_param_types, 1, 0),
            wrap_fn, &wrap_args, 1, "wrapped");

        const push_fn = self.getRuntimeFn("blimp_list_push", &.{ self.ptr_type, self.ptr_type }, self.void_type);
        var push_args = [_]c.LLVMValueRef{ result_list, wrapped };
        var push_param_types = [_]c.LLVMTypeRef{ self.ptr_type, self.ptr_type };
        _ = c.LLVMBuildCall2(self.builder,
            c.LLVMFunctionType(self.void_type, &push_param_types, 2, 0),
            push_fn, &push_args, 2, "");

        // RC: dec the wrapped value (list_push already inc'd it)
        self.emitRcDec(wrapped);

        // i++
        const next_i = c.LLVMBuildAdd(self.builder, i_val, c.LLVMConstInt(self.i32_type, 1, 0), "next_i");
        _ = c.LLVMBuildStore(self.builder, next_i, i_alloca);
        _ = c.LLVMBuildBr(self.builder, loop_bb);

        // End
        c.LLVMPositionBuilderAtEnd(self.builder, end_bb);
        return .{ .val = result_list, .tag = .tagged_val };
    }

    fn compileSpreadMap(self: *Codegen, se: ast.Node.SpreadExpr) CodegenError!TaggedVal {
        const list_tv = try self.compileExpr(se.iterable.*);
        const fn_tv = try self.compileExpr(se.func.*);
        const map_fn = self.getRuntimeFn("blimp_list_map", &.{ self.ptr_type, self.ptr_type }, self.ptr_type);
        var args = [_]c.LLVMValueRef{ list_tv.val, fn_tv.val };
        var param_types = [_]c.LLVMTypeRef{ self.ptr_type, self.ptr_type };
        const result = c.LLVMBuildCall2(self.builder,
            c.LLVMFunctionType(self.ptr_type, &param_types, 2, 0),
            map_fn, &args, 2, "mapped");
        return .{ .val = result, .tag = .tagged_val };
    }

    fn compileSpreadEach(self: *Codegen, se: ast.Node.SpreadExpr) CodegenError!TaggedVal {
        const list_tv = try self.compileExpr(se.iterable.*);
        const fn_tv = try self.compileExpr(se.func.*);
        const each_fn = self.getRuntimeFn("blimp_list_each", &.{ self.ptr_type, self.ptr_type }, self.void_type);
        var each_args = [_]c.LLVMValueRef{ list_tv.val, fn_tv.val };
        var each_param_types = [_]c.LLVMTypeRef{ self.ptr_type, self.ptr_type };
        _ = c.LLVMBuildCall2(self.builder,
            c.LLVMFunctionType(self.void_type, &each_param_types, 2, 0),
            each_fn, &each_args, 2, "");
        // Return :ok atom
        const ok_id = self.atoms.intern(self.allocator, "ok");
        return .{ .val = c.LLVMConstInt(self.i64_type, ok_id, 0), .tag = .atom };
    }

    fn compileDef(self: *Codegen, ds: ast.Node.DefStmt) CodegenError!TaggedVal {
        // Save current context
        const saved_fn = self.current_fn;
        const saved_scope = self.scope;
        const saved_tail_target = self.tail_call_target;
        self.scope = .{};

        // Create function: i64 name(i64, i64, ...)
        const param_count: u32 = @intCast(ds.params.len);
        var param_types = self.allocator.alloc(c.LLVMTypeRef, param_count) catch return CodegenError.LLVMError;
        for (0..param_count) |i| {
            param_types[i] = self.i64_type;
        }
        const fn_type = c.LLVMFunctionType(self.i64_type, param_types.ptr, param_count, 0);

        // Use existing forward declaration if present, otherwise create
        const fn_name = self.zname(ds.name);
        const func = c.LLVMGetNamedFunction(self.module, fn_name) orelse
            c.LLVMAddFunction(self.module, fn_name, fn_type);

        const entry_bb = c.LLVMAppendBasicBlock(func, "entry");
        c.LLVMPositionBuilderAtEnd(self.builder, entry_bb);
        self.current_fn = func;

        // Enable TCO: set tail_call_target so recursive calls get musttail
        self.tail_call_target = ds.name;

        // Bind params as i64 allocas
        for (ds.params, 0..) |param_name, i| {
            const alloca = c.LLVMBuildAlloca(self.builder, self.i64_type, self.zname(param_name.name));
            _ = c.LLVMBuildStore(self.builder, c.LLVMGetParam(func, @intCast(i)), alloca);
            self.scope.put(self.allocator, .{ .name = param_name.name, .alloca = alloca, .tag = .int, .llvm_type = self.i64_type });
        }

        // Compile body
        var last_tv: TaggedVal = .{ .val = c.LLVMConstInt(self.i64_type, 0, 0), .tag = .nil };
        for (ds.body) |stmt| {
            last_tv = try self.compileExpr(stmt);
        }

        // Return the last expression value
        if (c.LLVMGetBasicBlockTerminator(c.LLVMGetInsertBlock(self.builder)) == null) {
            _ = c.LLVMBuildRet(self.builder, last_tv.val);
        }

        // Restore context
        self.current_fn = saved_fn;
        self.scope = saved_scope;
        self.tail_call_target = saved_tail_target;

        // Position builder back in the calling function
        if (saved_fn) |f| {
            const last_bb = c.LLVMGetLastBasicBlock(f);
            c.LLVMPositionBuilderAtEnd(self.builder, last_bb);
        }

        // Return the function name as an atom (like the interpreter)
        const name_id = self.atoms.intern(self.allocator, ds.name);
        return .{ .val = c.LLVMConstInt(self.i64_type, name_id, 0), .tag = .atom };
    }

    fn compileListLit(self: *Codegen, ll: ast.Node.ListLit) CodegenError!TaggedVal {
        // Create list: blimp_val_list(cap)
        const make_fn = self.getRuntimeFn("blimp_val_list", &.{self.i32_type}, self.ptr_type);
        const cap = c.LLVMConstInt(self.i32_type, @intCast(ll.elements.len), 0);
        var make_args = [_]c.LLVMValueRef{cap};
        var make_pt = [_]c.LLVMTypeRef{self.i32_type};
        const list = c.LLVMBuildCall2(self.builder,
            c.LLVMFunctionType(self.ptr_type, &make_pt, 1, 0),
            make_fn, &make_args, 1, "list");

        // Push each element
        const push_fn = self.getRuntimeFn("blimp_list_push", &.{ self.ptr_type, self.ptr_type }, self.void_type);
        const wrap_int_fn = self.getRuntimeFn("blimp_val_int", &.{self.i64_type}, self.ptr_type);

        for (ll.elements) |elem| {
            const tv = try self.compileExpr(elem);
            // Wrap the i64 value as a BlimpVal
            var wrap_args = [_]c.LLVMValueRef{tv.val};
            var wrap_pt = [_]c.LLVMTypeRef{self.i64_type};
            const wrapped = c.LLVMBuildCall2(self.builder,
                c.LLVMFunctionType(self.ptr_type, &wrap_pt, 1, 0),
                wrap_int_fn, &wrap_args, 1, "elem_val");

            var push_args = [_]c.LLVMValueRef{ list, wrapped };
            var push_pt = [_]c.LLVMTypeRef{ self.ptr_type, self.ptr_type };
            _ = c.LLVMBuildCall2(self.builder,
                c.LLVMFunctionType(self.void_type, &push_pt, 2, 0),
                push_fn, &push_args, 2, "");

            // RC: dec local ref (list_push already inc'd)
            self.emitRcDec(wrapped);
        }

        return .{ .val = list, .tag = .tagged_val };
    }

    fn compileFnExpr(self: *Codegen, fe: ast.Node.FnExpr) CodegenError!TaggedVal {
        // Create an LLVM function for the closure body
        const cur_fn = self.current_fn;
        const saved_scope = self.scope;
        self.scope = .{};

        // Function type: BlimpVal*(BlimpVal*, ...) for each param
        const param_count: u32 = @intCast(fe.params.len);
        var param_types = self.allocator.alloc(c.LLVMTypeRef, param_count) catch return CodegenError.LLVMError;
        for (0..param_count) |i| {
            param_types[i] = self.ptr_type; // BlimpVal*
        }
        const fn_type = c.LLVMFunctionType(self.ptr_type, param_types.ptr, param_count, 0);
        const func = c.LLVMAddFunction(self.module, self.zname("blimp_closure"), fn_type);

        const entry_bb = c.LLVMAppendBasicBlock(func, "entry");
        c.LLVMPositionBuilderAtEnd(self.builder, entry_bb);
        self.current_fn = func;

        // Bind params: unwrap BlimpVal* to i64 for use in expressions
        const unwrap_fn = self.getRuntimeFn("blimp_val_to_int", &.{self.ptr_type}, self.i64_type);
        for (fe.params, 0..) |param_name, i| {
            var unwrap_args = [_]c.LLVMValueRef{c.LLVMGetParam(func, @intCast(i))};
            var unwrap_pt = [_]c.LLVMTypeRef{self.ptr_type};
            const unwrapped = c.LLVMBuildCall2(self.builder,
                c.LLVMFunctionType(self.i64_type, &unwrap_pt, 1, 0),
                unwrap_fn, &unwrap_args, 1, "unwrapped");
            const alloca = c.LLVMBuildAlloca(self.builder, self.i64_type, self.zname(param_name.name));
            _ = c.LLVMBuildStore(self.builder, unwrapped, alloca);
            self.scope.put(self.allocator, .{ .name = param_name.name, .alloca = alloca, .tag = .int, .llvm_type = self.i64_type });
        }

        // Compile body
        var last_tv: TaggedVal = .{ .val = c.LLVMConstInt(self.i64_type, 0, 0), .tag = .nil };
        for (fe.body) |stmt| {
            last_tv = try self.compileExpr(stmt);
        }

        // Wrap result as BlimpVal if it's an i64
        const wrap_fn = self.getRuntimeFn("blimp_val_int", &.{self.i64_type}, self.ptr_type);
        var wrap_args = [_]c.LLVMValueRef{last_tv.val};
        var wrap_pt = [_]c.LLVMTypeRef{self.i64_type};
        const wrapped = c.LLVMBuildCall2(self.builder,
            c.LLVMFunctionType(self.ptr_type, &wrap_pt, 1, 0),
            wrap_fn, &wrap_args, 1, "fn_result");
        _ = c.LLVMBuildRet(self.builder, wrapped);

        // Restore context
        self.current_fn = cur_fn;
        self.scope = saved_scope;

        // Position builder back in the calling function
        if (cur_fn) |f| {
            const last_bb = c.LLVMGetLastBasicBlock(f);
            c.LLVMPositionBuilderAtEnd(self.builder, last_bb);
        }

        // Create closure value: blimp_val_closure(func_ptr, param_count, null, 0)
        const closure_fn = self.getRuntimeFn("blimp_val_closure", &.{ self.ptr_type, self.i32_type, self.ptr_type, self.i32_type }, self.ptr_type);
        var closure_args = [_]c.LLVMValueRef{
            func,
            c.LLVMConstInt(self.i32_type, param_count, 0),
            c.LLVMConstNull(self.ptr_type), // no captured env yet
            c.LLVMConstInt(self.i32_type, 0, 0),
        };
        var closure_pt = [_]c.LLVMTypeRef{ self.ptr_type, self.i32_type, self.ptr_type, self.i32_type };
        const closure = c.LLVMBuildCall2(self.builder,
            c.LLVMFunctionType(self.ptr_type, &closure_pt, 4, 0),
            closure_fn, &closure_args, 4, "closure");

        return .{ .val = closure, .tag = .tagged_val };
    }

    // ── Perceus RC helpers ────────────────────────────────

    fn emitRcInc(self: *Codegen, val: c.LLVMValueRef) void {
        const f = self.getRuntimeFn("blimp_rc_inc", &.{self.ptr_type}, self.void_type);
        var params = [_]c.LLVMTypeRef{self.ptr_type};
        var args = [_]c.LLVMValueRef{val};
        _ = c.LLVMBuildCall2(self.builder,
            c.LLVMFunctionType(self.void_type, &params, 1, 0), f, &args, 1, "");
    }

    fn emitRcDec(self: *Codegen, val: c.LLVMValueRef) void {
        const f = self.getRuntimeFn("blimp_rc_dec", &.{self.ptr_type}, self.void_type);
        var params = [_]c.LLVMTypeRef{self.ptr_type};
        var args = [_]c.LLVMValueRef{val};
        _ = c.LLVMBuildCall2(self.builder,
            c.LLVMFunctionType(self.void_type, &params, 1, 0), f, &args, 1, "");
    }

    fn emitHandlerTable(self: *Codegen, actor: *const ActorDescriptor, actor_id: c.LLVMValueRef) void {
        // Build handler table: array of {i32 atom_id, ptr func, i32 param_count}
        // Stored on the stack, passed to blimp_set_handlers
        const handler_count: u32 = @intCast(actor.handler_fns.items.len);
        if (handler_count == 0) return;

        // Handler entry struct: {i32, ptr, i32}
        var entry_members = [_]c.LLVMTypeRef{ self.i32_type, self.ptr_type, self.i32_type };
        const entry_type = c.LLVMStructTypeInContext(self.context, &entry_members, 3, 0);
        const table_type = c.LLVMArrayType2(entry_type, handler_count);
        const table_alloca = c.LLVMBuildAlloca(self.builder, table_type, "handler_table");

        for (actor.handler_fns.items, 0..) |hfn, i| {
            const idx: u32 = @intCast(i);
            // GEP to table[i]
            var indices = [_]c.LLVMValueRef{
                c.LLVMConstInt(self.i32_type, 0, 0),
                c.LLVMConstInt(self.i32_type, idx, 0),
            };
            const elem_ptr = c.LLVMBuildGEP2(self.builder, table_type, table_alloca, &indices, 2, "entry_ptr");

            // Store atom_id
            const atom_gep = c.LLVMBuildStructGEP2(self.builder, entry_type, elem_ptr, 0, "atom_id");
            _ = c.LLVMBuildStore(self.builder, c.LLVMConstInt(self.i32_type, hfn.atom_id, 0), atom_gep);

            // Store function pointer
            const func_gep = c.LLVMBuildStructGEP2(self.builder, entry_type, elem_ptr, 1, "func_ptr");
            _ = c.LLVMBuildStore(self.builder, hfn.func, func_gep);

            // Store param count
            const pc_gep = c.LLVMBuildStructGEP2(self.builder, entry_type, elem_ptr, 2, "param_count");
            _ = c.LLVMBuildStore(self.builder, c.LLVMConstInt(self.i32_type, hfn.param_count, 0), pc_gep);
        }

        // blimp_set_handlers(actor_id, table_ptr, count)
        const set_fn = self.getRuntimeFn("blimp_set_handlers", &.{ self.i32_type, self.ptr_type, self.i32_type }, self.void_type);
        var set_args = [_]c.LLVMValueRef{
            actor_id,
            table_alloca,
            c.LLVMConstInt(self.i32_type, handler_count, 0),
        };
        var set_pt = [_]c.LLVMTypeRef{ self.i32_type, self.ptr_type, self.i32_type };
        _ = c.LLVMBuildCall2(
            self.builder,
            c.LLVMFunctionType(self.void_type, &set_pt, 3, 0),
            set_fn,
            &set_args,
            3,
            "",
        );
    }

    fn compileMessageSend(self: *Codegen, msg: ast.Node.MessageSend) CodegenError!TaggedVal {
        const target = try self.compileExpr(msg.target.*);

        // Target is now an actor_id (i64) -- truncate to i32 for the runtime
        const actor_id = c.LLVMBuildTrunc(self.builder, target.val, self.i32_type, "actor_id");

        // Intern message name
        const msg_atom_id = self.atoms.intern(self.allocator, msg.message);

        // Compile args into a stack array
        const arg_count: u32 = @intCast(msg.args.len);
        const args_alloca = if (arg_count > 0)
            c.LLVMBuildAlloca(self.builder, c.LLVMArrayType2(self.i64_type, arg_count), "args")
        else
            c.LLVMConstNull(self.ptr_type);

        for (msg.args, 0..) |arg, i| {
            const arg_val = try self.compileExpr(arg);
            // Actor refs get their ID as i64
            const store_val = arg_val.val;
            if (arg_count > 0) {
                var indices = [_]c.LLVMValueRef{
                    c.LLVMConstInt(self.i32_type, 0, 0),
                    c.LLVMConstInt(self.i32_type, @intCast(i), 0),
                };
                const elem = c.LLVMBuildGEP2(
                    self.builder,
                    c.LLVMArrayType2(self.i64_type, arg_count),
                    args_alloca,
                    &indices,
                    2,
                    "arg_ptr",
                );
                _ = c.LLVMBuildStore(self.builder, store_val, elem);
            }
        }

        // Call blimp_send(actor_id, handler_atom_id, arg_count, args_ptr) -> i64
        const send_fn = self.getRuntimeFn(
            "blimp_send",
            &.{ self.i32_type, self.i32_type, self.i32_type, self.ptr_type },
            self.i64_type,
        );
        var send_args = [_]c.LLVMValueRef{
            actor_id,
            c.LLVMConstInt(self.i32_type, msg_atom_id, 0),
            c.LLVMConstInt(self.i32_type, arg_count, 0),
            args_alloca,
        };
        var send_pt = [_]c.LLVMTypeRef{ self.i32_type, self.i32_type, self.i32_type, self.ptr_type };
        const send_ft = c.LLVMFunctionType(self.i64_type, &send_pt, 4, 0);
        const result = c.LLVMBuildCall2(self.builder, send_ft, send_fn, &send_args, 4, "send");
        return .{ .val = result, .tag = .int };
    }

    fn getMalloc(self: *Codegen) c.LLVMValueRef {
        const existing = c.LLVMGetNamedFunction(self.module, "malloc");
        if (existing != null) return existing;
        var param_types = [_]c.LLVMTypeRef{self.i64_type};
        const ft = c.LLVMFunctionType(self.ptr_type, &param_types, 1, 0);
        return c.LLVMAddFunction(self.module, "malloc", ft);
    }

    fn getRuntimeFn(self: *Codegen, name: [*:0]const u8, param_types: []const c.LLVMTypeRef, ret_type: c.LLVMTypeRef) c.LLVMValueRef {
        const existing = c.LLVMGetNamedFunction(self.module, name);
        if (existing != null) return existing;
        const ft = c.LLVMFunctionType(ret_type, @constCast(param_types.ptr), @intCast(param_types.len), 0);
        return c.LLVMAddFunction(self.module, name, ft);
    }

    // ── Branching (situation/case/orelse) ───────────────────

    /// Compile situation/case: chain of icmp + conditional branches.
    /// Both work the same way -- situation allows holes, case requires exhaustiveness,
    /// but codegen treats them identically.
    fn compileBranching(self: *Codegen, subject_node: *const ast.Node, branches: []const ast.Node.Branch) CodegenError!TaggedVal {
        const func = self.current_fn orelse return CodegenError.LLVMError;
        const subject = try self.compileExpr(subject_node.*);

        const merge_bb = c.LLVMAppendBasicBlockInContext(self.context, func, "merge");

        // We'll collect {value, block} pairs for the phi node
        var phi_vals: [16]c.LLVMValueRef = undefined;
        var phi_blocks: [16]c.LLVMBasicBlockRef = undefined;
        var phi_count: u32 = 0;

        for (branches, 0..) |branch, idx| {
            const is_wildcard = branch.pattern == null or
                (branch.pattern != null and branch.pattern.?.kind == .hole);
            const is_var_bind = !is_wildcard and branch.pattern != null and
                branch.pattern.?.kind == .identifier;

            if (is_wildcard or (is_var_bind and branch.guard == null)) {
                // Wildcard/hole or unguarded variable bind: unconditional branch
                if (is_var_bind) {
                    const var_name = branch.pattern.?.kind.identifier.name;
                    const alloca = c.LLVMBuildAlloca(self.builder, self.i64_type, self.zname(var_name));
                    _ = c.LLVMBuildStore(self.builder, subject.val, alloca);
                    self.scope.put(self.allocator, .{
                        .name = var_name,
                        .alloca = alloca,
                        .tag = subject.tag,
                        .llvm_type = self.i64_type,
                    });
                }
                var last_val: TaggedVal = .{ .val = c.LLVMConstInt(self.i64_type, 0, 0), .tag = .nil };
                for (branch.body) |stmt| {
                    last_val = try self.compileExpr(stmt);
                }
                // Only branch to merge if body didn't already terminate (e.g. reply/ret)
                const bb = c.LLVMGetInsertBlock(self.builder);
                if (c.LLVMGetBasicBlockTerminator(bb) == null) {
                    if (phi_count < 16) {
                        phi_vals[phi_count] = last_val.val;
                        phi_blocks[phi_count] = bb;
                        phi_count += 1;
                    }
                    _ = c.LLVMBuildBr(self.builder, merge_bb);
                }
                break; // Unconditional branch is always last
            } else if (is_var_bind) {
                // Variable bind with guard: bind subject to var, then test guard
                const var_name = branch.pattern.?.kind.identifier.name;
                const alloca = c.LLVMBuildAlloca(self.builder, self.i64_type, self.zname(var_name));
                _ = c.LLVMBuildStore(self.builder, subject.val, alloca);
                self.scope.put(self.allocator, .{
                    .name = var_name,
                    .alloca = alloca,
                    .tag = subject.tag,
                    .llvm_type = self.i64_type,
                });

                const guard_val = try self.compileExpr(branch.guard.?.*);
                const zero = c.LLVMConstInt(self.i64_type, 0, 0);
                const guard_bool = c.LLVMBuildICmp(self.builder, c.LLVMIntNE, guard_val.val, zero, "guard");

                const then_bb = c.LLVMAppendBasicBlockInContext(self.context, func, "then");
                const is_last = idx + 1 >= branches.len;
                const else_bb = if (!is_last)
                    c.LLVMAppendBasicBlockInContext(self.context, func, "else")
                else
                    merge_bb;

                _ = c.LLVMBuildCondBr(self.builder, guard_bool, then_bb, else_bb);

                if (is_last and phi_count < 16) {
                    phi_vals[phi_count] = c.LLVMConstInt(self.i64_type, 0, 0);
                    phi_blocks[phi_count] = c.LLVMGetInsertBlock(self.builder);
                    phi_count += 1;
                }

                c.LLVMPositionBuilderAtEnd(self.builder, then_bb);
                var last_val: TaggedVal = .{ .val = c.LLVMConstInt(self.i64_type, 0, 0), .tag = .nil };
                for (branch.body) |stmt| {
                    last_val = try self.compileExpr(stmt);
                }
                const then_end = c.LLVMGetInsertBlock(self.builder);
                if (c.LLVMGetBasicBlockTerminator(then_end) == null) {
                    if (phi_count < 16) {
                        phi_vals[phi_count] = last_val.val;
                        phi_blocks[phi_count] = then_end;
                        phi_count += 1;
                    }
                    _ = c.LLVMBuildBr(self.builder, merge_bb);
                }

                if (!is_last) {
                    c.LLVMPositionBuilderAtEnd(self.builder, else_bb);
                }
            } else {
                // Literal pattern match: compare subject to pattern value
                const pattern = try self.compileExpr(branch.pattern.?.*);
                var lhs_val = subject.val;
                var rhs_val = pattern.val;
                const lhs_type = c.LLVMTypeOf(lhs_val);
                const rhs_type = c.LLVMTypeOf(rhs_val);
                if (lhs_type != rhs_type) {
                    if (c.LLVMGetIntTypeWidth(lhs_type) < c.LLVMGetIntTypeWidth(rhs_type)) {
                        lhs_val = c.LLVMBuildZExt(self.builder, lhs_val, rhs_type, "widen_l");
                    } else {
                        rhs_val = c.LLVMBuildZExt(self.builder, rhs_val, lhs_type, "widen_r");
                    }
                }

                var cmp = c.LLVMBuildICmp(self.builder, c.LLVMIntEQ, lhs_val, rhs_val, "branchtmp");
                if (branch.guard) |guard_node| {
                    const guard_val = try self.compileExpr(guard_node.*);
                    const zero = c.LLVMConstInt(self.i64_type, 0, 0);
                    const guard_bool = c.LLVMBuildICmp(self.builder, c.LLVMIntNE, guard_val.val, zero, "guard");
                    cmp = c.LLVMBuildAnd(self.builder, cmp, guard_bool, "match_and_guard");
                }

                const then_bb = c.LLVMAppendBasicBlockInContext(self.context, func, "then");
                const is_last = idx + 1 >= branches.len;
                const else_bb = if (!is_last)
                    c.LLVMAppendBasicBlockInContext(self.context, func, "else")
                else
                    merge_bb;

                _ = c.LLVMBuildCondBr(self.builder, cmp, then_bb, else_bb);

                if (is_last and phi_count < 16) {
                    phi_vals[phi_count] = c.LLVMConstInt(self.i64_type, 0, 0);
                    phi_blocks[phi_count] = c.LLVMGetInsertBlock(self.builder);
                    phi_count += 1;
                }

                c.LLVMPositionBuilderAtEnd(self.builder, then_bb);
                var last_val: TaggedVal = .{ .val = c.LLVMConstInt(self.i64_type, 0, 0), .tag = .nil };
                for (branch.body) |stmt| {
                    last_val = try self.compileExpr(stmt);
                }
                const then_end = c.LLVMGetInsertBlock(self.builder);
                if (c.LLVMGetBasicBlockTerminator(then_end) == null) {
                    if (phi_count < 16) {
                        phi_vals[phi_count] = last_val.val;
                        phi_blocks[phi_count] = then_end;
                        phi_count += 1;
                    }
                    _ = c.LLVMBuildBr(self.builder, merge_bb);
                }

                if (!is_last) {
                    c.LLVMPositionBuilderAtEnd(self.builder, else_bb);
                }
            }
        }

        // If we're in a block that hasn't been terminated yet (no wildcard matched),
        // add a default nil branch to merge
        const current_bb = c.LLVMGetInsertBlock(self.builder);
        if (current_bb != merge_bb and c.LLVMGetBasicBlockTerminator(current_bb) == null) {
            if (phi_count < 16) {
                phi_vals[phi_count] = c.LLVMConstInt(self.i64_type, 0, 0);
                phi_blocks[phi_count] = current_bb;
                phi_count += 1;
            }
            _ = c.LLVMBuildBr(self.builder, merge_bb);
        }

        // Build phi in merge block
        c.LLVMPositionBuilderAtEnd(self.builder, merge_bb);

        if (phi_count == 0) {
            // All branches terminated (reply/ret) -- merge is dead code.
            // Delete the empty merge block and position at the last block.
            c.LLVMDeleteBasicBlock(merge_bb);
            // Position at last basic block of function so subsequent codegen works
            const last_bb = c.LLVMGetLastBasicBlock(func);
            c.LLVMPositionBuilderAtEnd(self.builder, last_bb);
            return .{ .val = c.LLVMConstInt(self.i64_type, 0, 0), .tag = .nil };
        }

        const phi = c.LLVMBuildPhi(self.builder, self.i64_type, "result");
        c.LLVMAddIncoming(phi, &phi_vals, &phi_blocks, phi_count);
        return .{ .val = phi, .tag = .int };
    }

    fn compileSituation(self: *Codegen, sit: ast.Node.Situation) CodegenError!TaggedVal {
        return self.compileBranching(sit.subject, sit.branches);
    }

    fn compileCase(self: *Codegen, cas: ast.Node.CaseExpr) CodegenError!TaggedVal {
        return self.compileBranching(cas.subject, cas.branches);
    }

    fn compileOrelse(self: *Codegen, ore: ast.Node.OrElseExpr) CodegenError!TaggedVal {
        const func = self.current_fn orelse return CodegenError.LLVMError;
        const try_val = try self.compileExpr(ore.try_expr.*);

        // Compare against nil (0 for i64 values)
        const zero = c.LLVMConstInt(self.i64_type, 0, 0);
        const is_nil = c.LLVMBuildICmp(self.builder, c.LLVMIntEQ, try_val.val, zero, "isniltmp");

        const fallback_bb = c.LLVMAppendBasicBlockInContext(self.context, func, "fallback");
        const merge_bb = c.LLVMAppendBasicBlockInContext(self.context, func, "orelse_merge");
        const try_bb = c.LLVMGetInsertBlock(self.builder);

        _ = c.LLVMBuildCondBr(self.builder, is_nil, fallback_bb, merge_bb);

        // Fallback block
        c.LLVMPositionBuilderAtEnd(self.builder, fallback_bb);
        const fallback_val = try self.compileExpr(ore.fallback.*);
        const fallback_end_bb = c.LLVMGetInsertBlock(self.builder);
        _ = c.LLVMBuildBr(self.builder, merge_bb);

        // Merge with phi -- coerce both to i64 for uniform type
        c.LLVMPositionBuilderAtEnd(self.builder, merge_bb);
        const phi = c.LLVMBuildPhi(self.builder, self.i64_type, "orelse");
        var vals = [_]c.LLVMValueRef{ self.coerceToI64(try_val), self.coerceToI64(fallback_val) };
        var blocks = [_]c.LLVMBasicBlockRef{ try_bb, fallback_end_bb };
        c.LLVMAddIncoming(phi, &vals, &blocks, 2);

        return .{ .val = phi, .tag = .int };
    }

    // ── Program building ─────────────────────────────────────

    /// Build a complete program from a list of top-level AST nodes.
    /// Executes statements in sequence, prints the last expression.
    pub fn buildProgram(self: *Codegen, nodes: []const ast.Node) CodegenError!void {
        // Define: i32 main()
        var main_param_types = [_]c.LLVMTypeRef{};
        const main_func_type = c.LLVMFunctionType(self.i32_type, &main_param_types, 0, 0);
        const main_func = c.LLVMAddFunction(self.module, "main", main_func_type);
        self.current_fn = main_func;

        const entry = c.LLVMAppendBasicBlockInContext(self.context, main_func, "entry");
        c.LLVMPositionBuilderAtEnd(self.builder, entry);

        // Forward-declare all def functions so order doesn't matter
        self.forwardDeclareDefs(nodes);

        // Canvas mode: enable event logging at program start
        if (self.canvas_mode) {
            const enable_fn = self.getRuntimeFn("blimp_canvas_enable", &.{}, self.void_type);
            _ = c.LLVMBuildCall2(self.builder, c.LLVMFunctionType(self.void_type, &[_]c.LLVMTypeRef{}, 0, 0), enable_fn, &[_]c.LLVMValueRef{}, 0, "");
        }

        // Compile all nodes; track the last result for printing
        var last: ?TaggedVal = null;
        for (nodes) |node| {
            last = try self.compileExpr(node);
        }

        // Canvas mode: register atom names (must be after compilation interns all atoms)
        if (self.canvas_mode) {
            self.emitCanvasSetup();
        }

        // Drain any remaining async messages
        const sched_fn = self.getRuntimeFn("blimp_scheduler_run", &.{}, self.void_type);
        const sched_ft = c.LLVMFunctionType(self.void_type, &[_]c.LLVMTypeRef{}, 0, 0);
        _ = c.LLVMBuildCall2(self.builder, sched_ft, sched_fn, &[_]c.LLVMValueRef{}, 0, "");

        // Print the last result
        if (last) |result| {
            self.emitPrint(result);
        }

        // Canvas mode: dump event log
        if (self.canvas_mode) {
            self.emitCanvasDump("blimp_canvas.json");
        }

        // Return 0
        _ = c.LLVMBuildRet(self.builder, c.LLVMConstInt(self.i32_type, 0, 0));
    }

    /// Forward-declare all `def` functions so call order doesn't matter.
    fn forwardDeclareDefs(self: *Codegen, nodes: []const ast.Node) void {
        for (nodes) |node| {
            if (node.kind == .def_stmt) {
                const ds = node.kind.def_stmt;
                // Only declare if not already present
                if (c.LLVMGetNamedFunction(self.module, self.zname(ds.name)) == null) {
                    const param_count: u32 = @intCast(ds.params.len);
                    const param_types = self.allocator.alloc(c.LLVMTypeRef, param_count) catch continue;
                    for (0..param_count) |i| {
                        param_types[i] = self.i64_type;
                    }
                    const fn_type = c.LLVMFunctionType(self.i64_type, param_types.ptr, param_count, 0);
                    _ = c.LLVMAddFunction(self.module, self.zname(ds.name), fn_type);
                }
            }
        }
    }

    /// Backward-compat: build main from a single expression.
    pub fn buildMainFunction(self: *Codegen, expr: ast.Node) CodegenError!void {
        return self.buildProgram(&.{expr});
    }

    fn emitPrint(self: *Codegen, tv: TaggedVal) void {
        switch (tv.tag) {
            .int => {
                const f = self.getPrintInt();
                var params = [_]c.LLVMTypeRef{self.i64_type};
                const ft = c.LLVMFunctionType(self.void_type, &params, 1, 0);
                var args = [_]c.LLVMValueRef{tv.val};
                _ = c.LLVMBuildCall2(self.builder, ft, f, &args, 1, "");
            },
            .float => {
                const f = self.getPrintFloat();
                var params = [_]c.LLVMTypeRef{self.f64_type};
                const ft = c.LLVMFunctionType(self.void_type, &params, 1, 0);
                var args = [_]c.LLVMValueRef{tv.val};
                _ = c.LLVMBuildCall2(self.builder, ft, f, &args, 1, "");
            },
            .boolean => {
                const f = self.getPrintBool();
                var params = [_]c.LLVMTypeRef{self.i64_type};
                const ft = c.LLVMFunctionType(self.void_type, &params, 1, 0);
                var args = [_]c.LLVMValueRef{tv.val};
                _ = c.LLVMBuildCall2(self.builder, ft, f, &args, 1, "");
            },
            .string => {
                const f = self.getPrintString();
                var params = [_]c.LLVMTypeRef{self.ptr_type};
                const ft = c.LLVMFunctionType(self.void_type, &params, 1, 0);
                var args = [_]c.LLVMValueRef{tv.val};
                _ = c.LLVMBuildCall2(self.builder, ft, f, &args, 1, "");
            },
            .atom => {
                // Resolve atom ID back to name string for printing
                // tv.val is a constant i32 -- extract the ID
                const f = self.getPrintAtom();
                var params = [_]c.LLVMTypeRef{self.ptr_type};
                const ft = c.LLVMFunctionType(self.void_type, &params, 1, 0);
                // Try to get the atom name from the intern table
                const atom_id = c.LLVMConstIntGetZExtValue(tv.val);
                if (atom_id < self.atoms.names.items.len) {
                    const name = self.atoms.names.items[@intCast(atom_id)];
                    const str_ptr = c.LLVMBuildGlobalStringPtr(self.builder, self.zname(name), "atom_name");
                    var args = [_]c.LLVMValueRef{str_ptr};
                    _ = c.LLVMBuildCall2(self.builder, ft, f, &args, 1, "");
                } else {
                    const str_ptr = c.LLVMBuildGlobalStringPtr(self.builder, "?", "atom_unknown");
                    var args = [_]c.LLVMValueRef{str_ptr};
                    _ = c.LLVMBuildCall2(self.builder, ft, f, &args, 1, "");
                }
            },
            .nil => {
                const f = self.getPrintNil();
                const ft = c.LLVMFunctionType(self.void_type, &[_]c.LLVMTypeRef{}, 0, 0);
                _ = c.LLVMBuildCall2(self.builder, ft, f, &[_]c.LLVMValueRef{}, 0, "");
            },
            .actor_ref => {
                // Print actor ref as its ID
                const f = self.getPrintInt();
                var params = [_]c.LLVMTypeRef{self.i64_type};
                const ft = c.LLVMFunctionType(self.void_type, &params, 1, 0);
                var args = [_]c.LLVMValueRef{tv.val};
                _ = c.LLVMBuildCall2(self.builder, ft, f, &args, 1, "");
            },
            .tagged_val => {
                // Print via runtime: blimp_print_val(BlimpVal*)
                const f = self.getRuntimeFn("blimp_print_val", &.{self.ptr_type}, self.void_type);
                var params = [_]c.LLVMTypeRef{self.ptr_type};
                const ft = c.LLVMFunctionType(self.void_type, &params, 1, 0);
                var args = [_]c.LLVMValueRef{tv.val};
                _ = c.LLVMBuildCall2(self.builder, ft, f, &args, 1, "");
            },
        }
    }

    // ── Verification & emission ──────────────────────────────

    pub fn verify(self: *Codegen) CodegenError!void {
        var err_msg: [*c]u8 = null;
        if (c.LLVMVerifyModule(self.module, c.LLVMReturnStatusAction, &err_msg) != 0) {
            if (err_msg) |msg| {
                std.debug.print("LLVM verification error: {s}\n", .{msg});
                c.LLVMDisposeMessage(msg);
            }
            return CodegenError.VerificationFailed;
        }
    }

    pub fn dumpIR(self: *Codegen) void {
        c.LLVMDumpModule(self.module);
    }

    /// Run LLVM optimization passes (O2) on the module.
    pub fn optimize(self: *Codegen) CodegenError!void {
        _ = c.LLVMInitializeNativeTarget();
        _ = c.LLVMInitializeNativeAsmPrinter();

        const triple = c.LLVMGetDefaultTargetTriple();
        defer c.LLVMDisposeMessage(triple);

        var target: c.LLVMTargetRef = null;
        var target_err: [*c]u8 = null;
        if (c.LLVMGetTargetFromTriple(triple, &target, &target_err) != 0) {
            if (target_err) |msg| c.LLVMDisposeMessage(msg);
            return CodegenError.TargetError;
        }

        const cpu = c.LLVMGetHostCPUName();
        defer c.LLVMDisposeMessage(cpu);
        const features = c.LLVMGetHostCPUFeatures();
        defer c.LLVMDisposeMessage(features);

        const machine = c.LLVMCreateTargetMachine(
            target, triple, cpu, features,
            c.LLVMCodeGenLevelAggressive,
            c.LLVMRelocDefault, c.LLVMCodeModelDefault,
        );
        defer c.LLVMDisposeTargetMachine(machine);

        const opts = c.LLVMCreatePassBuilderOptions();
        defer c.LLVMDisposePassBuilderOptions(opts);

        const err = c.LLVMRunPasses(self.module, "default<O3>,tailcallelim", machine, opts);
        if (err != null) {
            const msg = c.LLVMGetErrorMessage(err);
            std.debug.print("LLVM optimize error: {s}\n", .{msg});
            c.LLVMDisposeErrorMessage(msg);
            return CodegenError.LLVMError;
        }
    }

    pub fn emitObjectFile(self: *Codegen, output_path: [*:0]const u8) CodegenError!void {
        _ = c.LLVMInitializeNativeTarget();
        _ = c.LLVMInitializeNativeAsmPrinter();
        _ = c.LLVMInitializeNativeAsmParser();

        const triple = c.LLVMGetDefaultTargetTriple();
        defer c.LLVMDisposeMessage(triple);

        var target: c.LLVMTargetRef = null;
        var err_msg: [*c]u8 = null;
        if (c.LLVMGetTargetFromTriple(triple, &target, &err_msg) != 0) {
            if (err_msg) |msg| {
                std.debug.print("LLVM target error: {s}\n", .{msg});
                c.LLVMDisposeMessage(msg);
            }
            return CodegenError.TargetError;
        }

        const cpu = c.LLVMGetHostCPUName();
        defer c.LLVMDisposeMessage(cpu);
        const features = c.LLVMGetHostCPUFeatures();
        defer c.LLVMDisposeMessage(features);

        const machine = c.LLVMCreateTargetMachine(
            target,
            triple,
            cpu,
            features,
            c.LLVMCodeGenLevelAggressive,
            c.LLVMRelocDefault,
            c.LLVMCodeModelDefault,
        );
        defer c.LLVMDisposeTargetMachine(machine);

        c.LLVMSetTarget(self.module, triple);
        const data_layout = c.LLVMCreateTargetDataLayout(machine);
        c.LLVMSetModuleDataLayout(self.module, data_layout);
        c.LLVMDisposeTargetData(data_layout);

        var emit_err: [*c]u8 = null;
        if (c.LLVMTargetMachineEmitToFile(machine, self.module, output_path, c.LLVMObjectFile, &emit_err) != 0) {
            if (emit_err) |msg| {
                std.debug.print("LLVM emit error: {s}\n", .{msg});
                c.LLVMDisposeMessage(msg);
            }
            return CodegenError.EmitError;
        }
    }

    /// Emit LLVM bitcode file (for LTO -- the linker can optimize across modules).
    pub fn emitBitcodeFile(self: *Codegen, output_path: [*:0]const u8) CodegenError!void {
        if (c.LLVMWriteBitcodeToFile(self.module, output_path) != 0) {
            std.debug.print("LLVM bitcode emit error\n", .{});
            return CodegenError.EmitError;
        }
    }
};
