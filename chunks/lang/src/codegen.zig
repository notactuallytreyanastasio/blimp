const std = @import("std");
const ast = @import("ast.zig");
const errors = @import("errors.zig");

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

/// The status byte of a handler result and of a send: `{i8 status, i64 value}`.
/// runtime.c's `BLIMP_*` enum carries the same numbers.  For `bubble` and
/// `fault` the value is a `BlimpRaise*` holding the reason and the site.
const Status = struct {
    const nomatch: u64 = 0; // guard failed: the runtime tries the next clause
    const ok: u64 = 1;
    const nil: u64 = 2; // ended without a reply, or replied nil
    const bubble: u64 = 3; // caught by try and by orelse
    const fault: u64 = 4; // runtime error: caught by try only
};

/// A construct codegen refused, and where.  compile_main prints it.
pub const Failure = struct {
    loc: ast.Loc,
    message: []const u8,
    hint: []const u8,
};

/// A `try` or `orelse` enclosing the code being compiled, innermost last.
/// A raise in the same function branches to the innermost one that takes it.
const Catch = struct {
    kind: enum { try_, orelse_ },
    landing: c.LLVMBasicBlockRef,
    /// try only: where the BlimpRaise* is left for the catch block
    slot: c.LLVMValueRef,
    loc: ast.Loc,
};

/// Variable scope: maps names to LLVM alloca pointers + type tags.
/// Uses a simple linear scan (fine for REPL-scale programs).
const Scope = struct {
    const Entry = struct {
        name: []const u8,
        alloca: c.LLVMValueRef,
        tag: Codegen.ValTag,
        llvm_type: c.LLVMTypeRef,
        /// A name compiled code cannot bind (a handler parameter of a type
        /// it does not carry): reading it is refused with this message.
        unbound: ?[]const u8 = null,
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
        /// What crosses the send, decided when the handler is compiled:
        /// the tag of each parameter (from its annotation) and the tags
        /// its replies carry (one bit per ValTag; nil is `may_nil`).
        /// null: a type compiled code does not carry; the parameter is
        /// refused where it is read, and every send to it in checkSends.
        param_tags: []const ?Codegen.ValTag,
        reply_mask: u16,
        may_nil: bool,
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
    i8_type: c.LLVMTypeRef,
    handler_ret_type: c.LLVMTypeRef, // {i8, i64} -- Status + value
    site_type: c.LLVMTypeRef, // {i32 line, i32 col, ptr source_line} -- BlimpSite
    // Current function being built (needed for creating basic blocks)
    current_fn: ?c.LLVMValueRef = null,
    /// What the function being built can do with a bubble nothing in it
    /// catches: a handler returns it to the sender; main and a def have no
    /// one to hand it to.
    fn_kind: enum { main, handler, def } = .main,
    /// The def (or "fn") being compiled, for messages.
    current_def_name: []const u8 = "",
    /// Enclosing try/orelse in the current function.
    catches: std.ArrayList(Catch) = .empty,
    /// Every def: what a call by its name resolves to; a call to one inside
    /// a try/orelse is refused.
    defs: std.ArrayList(ast.Node.DefStmt) = .empty,
    /// Status of the send compiled last, so `orelse` can tell a reply of 0
    /// from no reply at all.
    last_send_status: ?c.LLVMValueRef = null,
    /// Set by `orelse` for the send that is its left side: that send may
    /// end without a reply, since the status takes the fallback.
    send_under_orelse: bool = false,
    /// The send compiled last cannot hand back a value (no handler of that
    /// name, or every one only raises), so `orelse` takes only its fallback.
    last_send_never: bool = false,
    /// Replies of the handler being compiled (see HandlerFn).
    reply_mask: u16 = 0,
    reply_may_nil: bool = false,
    /// Every send, with the reply tag it was compiled for, checked again in
    /// checkSends once every handler is compiled.
    sends: std.ArrayList(SendCheck) = .empty,
    /// Every actor the program declares, for a parameter typed with one.
    actor_names: std.ArrayList([]const u8) = .empty,
    /// Program text, for the source line a runtime report shows.
    source: []const u8 = "",
    /// Set when codegen refuses a construct; the first one set is reported.
    failure: ?Failure = null,
    // When set, compileFuncCall marks calls to this name with musttail
    tail_call_target: ?[]const u8 = null,
    // Current actor context (set during handler compilation)
    current_actor: ?*ActorDescriptor = null,
    // Cached runtime function refs (lazily declared)
    print_int_fn: ?c.LLVMValueRef = null,
    print_float_fn: ?c.LLVMValueRef = null,
    print_bool_fn: ?c.LLVMValueRef = null,
    print_string_fn: ?c.LLVMValueRef = null,
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
            .i8_type = c.LLVMInt8TypeInContext(ctx),
            .handler_ret_type = blk: {
                var members = [_]c.LLVMTypeRef{
                    c.LLVMInt8TypeInContext(ctx),
                    c.LLVMInt64TypeInContext(ctx),
                };
                break :blk c.LLVMStructTypeInContext(ctx, &members, 2, 0);
            },
            .site_type = blk: {
                var members = [_]c.LLVMTypeRef{
                    c.LLVMInt32TypeInContext(ctx),
                    c.LLVMInt32TypeInContext(ctx),
                    c.LLVMPointerTypeInContext(ctx, 0),
                };
                break :blk c.LLVMStructTypeInContext(ctx, &members, 3, 0);
            },
        };
    }

    pub fn deinit(self: *Codegen) void {
        self.catches.deinit(self.allocator);
        self.sends.deinit(self.allocator);
        self.actor_names.deinit(self.allocator);
        self.defs.deinit(self.allocator);
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

    fn tagBit(tag: ValTag) u16 {
        return @as(u16, 1) << @intFromEnum(tag);
    }

    /// A send as compiled: what its reply was taken to be, and the tags of
    /// its arguments.  A handler compiled after the send (one actor sending
    /// to another declared later, or to itself) can disagree; checkSends
    /// refuses the send then.
    const SendCheck = struct {
        message: []const u8,
        loc: ast.Loc,
        under_orelse: bool,
        reply: ValTag,
        never: bool,
        /// null: an unbound parameter passed on as it is.
        arg_tags: []const ?ValTag,
        arg_locs: []const ast.Loc,
    };

    /// Compile an expression, returning the value and its type tag.
    pub fn compileExpr(self: *Codegen, node: ast.Node) CodegenError!TaggedVal {
        return self.compileNode(node) catch |err| {
            // The innermost node that failed is the first to get here.
            if (self.failure == null) {
                self.failure = .{
                    .loc = node.loc,
                    .message = if (err == CodegenError.UndefinedVariable and node.kind == .identifier)
                        std.fmt.allocPrint(self.allocator, "Nothing called `{s}` is in scope here.", .{node.kind.identifier.name}) catch "undefined variable"
                    else
                        std.fmt.allocPrint(self.allocator, "The compiler does not handle this `{s}` yet.", .{@tagName(node.kind)}) catch "unsupported construct",
                    .hint = "Run this file with the interpreter.",
                };
            }
            return err;
        };
    }

    /// Refuse a construct: compile_main reports `message` at `loc`.
    fn reject(self: *Codegen, loc: ast.Loc, comptime fmt: []const u8, args: anytype, hint: []const u8) CodegenError {
        self.failure = .{
            .loc = loc,
            .message = std.fmt.allocPrint(self.allocator, fmt, args) catch fmt,
            .hint = hint,
        };
        return CodegenError.UnsupportedNode;
    }

    fn compileNode(self: *Codegen, node: ast.Node) CodegenError!TaggedVal {
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
            .identifier => |id| self.compileIdentifier(id, node.loc),
            .binary_op => |op| self.compileBinaryOp(op, node.loc),
            .unary_op => |op| self.compileUnaryOp(op),
            .assign_stmt => |stmt| self.compileAssign(stmt),
            .func_call => |call| self.compileFuncCall(call, node.loc),
            .pipe_expr => |pipe| self.compilePipe(pipe),
            .situation => |sit| self.compileSituation(sit),
            .case_expr => |cas| self.compileCase(cas),
            .orelse_expr => |ore| self.compileOrelse(ore, node.loc),
            .try_catch => |tc| self.compileTryCatch(tc, node.loc),
            .dot_access => |dot| self.compileDotAccess(dot),
            .actor_def => |def| self.compileActorDef(def),
            .spawn_expr => |spn| self.compileSpawn(spn),
            .struct_lit => |sl| self.compileStructLit(sl),
            .bubble_stmt => |bs| self.compileBubble(bs, node.loc),
            .map_lit => |ml| self.compileMapLit(ml),
            .message_send => |msg| self.compileMessageSend(msg, node.loc),
            .become_stmt => |bec| self.compileBecome(bec),
            .reply_stmt => |rep| self.compileReply(rep),
            .self_ref => self.compileSelfRef(),
            .for_expr => |fe| self.compileFor(fe),
            .spread_map => |se| self.compileSpreadMap(se),
            .spread_each => |se| self.compileSpreadEach(se),
            .list_lit => |ll| self.compileListLit(ll),
            .fn_expr => |fe| self.compileFnExpr(fe, node.loc),
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

    fn compileIdentifier(self: *Codegen, id: ast.Node.Identifier, loc: ast.Loc) CodegenError!TaggedVal {
        const entry = self.scope.get(id.name) orelse return CodegenError.UndefinedVariable;
        if (entry.unbound) |why| return self.reject(loc, "{s}", .{why}, "Run this file with the interpreter.");
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

    /// A def returns a bare i64, so a bubble or fault inside one has no way
    /// back to a try/orelse around the call (it aborts the program instead).
    /// Refused here rather than compiled into a catch that cannot fire.
    fn checkDefCallCatchable(self: *Codegen, name: []const u8) CodegenError!void {
        if (self.catches.items.len == 0) return;
        for (self.defs.items) |d| {
            if (!std.mem.eql(u8, d.name, name)) continue;
            const k = self.catches.items[self.catches.items.len - 1];
            return self.reject(
                k.loc,
                "`{s}` around a call to `{s}`: a bubble or a division by zero inside a def cannot reach this catch in compiled code.",
                .{ if (k.kind == .try_) "try" else "orelse", name },
                "Call the def outside the `try`, or run this file with the interpreter.",
            );
        }
    }

    fn findDef(self: *const Codegen, name: []const u8) ?ast.Node.DefStmt {
        for (self.defs.items) |d| if (std.mem.eql(u8, d.name, name)) return d;
        return null;
    }

    /// What a call by name runs.  The interpreter looks the name up in the
    /// environment first (a closure there is called, and a def is one), and
    /// only then among its builtins; a local that is not a closure hides a
    /// def of the same name.  Anything else is refused here, by name: there
    /// is no "call a C function of that name" case, because Blimp has no
    /// foreign calls and every such symbol the linker found was an accident.
    const Callee = union(enum) {
        def: ast.Node.DefStmt,
        builtin: Builtin,
        /// A local holding a value: called as a closure, checked at run time.
        closure: Scope.Entry,
    };

    /// The builtins compiled code provides.  Every other interpreter builtin
    /// is refused at the call.
    const Builtin = enum { max, min, rem, abs, puts };
    const builtin_list = "max, min, rem, abs, puts";

    fn resolveCallee(self: *Codegen, name: []const u8, loc: ast.Loc, argc: usize) CodegenError!Callee {
        const local = self.scope.get(name);
        if (local) |entry| if (entry.unbound) |why| return self.reject(loc, "{s}", .{why}, "Run this file with the interpreter.");
        if (local) |entry| if (entry.tag == .tagged_val) {
            // A fault inside a closure body ends the program (a closure,
            // like a def, has no channel back to the caller's catch).
            if (self.catches.items.len > 0) {
                const k = self.catches.items[self.catches.items.len - 1];
                return self.reject(
                    k.loc,
                    "`{s}` around a call of the fn value `{s}`: a fault inside it cannot reach this catch in compiled code.",
                    .{ if (k.kind == .try_) "try" else "orelse", name },
                    "Call it outside the `try`, or run this file with the interpreter.",
                );
            }
            return .{ .closure = entry };
        };
        if (local == null) if (self.findDef(name)) |d| {
            if (d.params.len != argc) return self.reject(
                loc,
                "`{s}` takes {d} argument(s); this call passes {d}.",
                .{ name, d.params.len, argc },
                "Pass one argument for each parameter of the def.",
            );
            return .{ .def = d };
        };
        if (std.meta.stringToEnum(Builtin, name)) |b| {
            const want: usize = switch (b) {
                .max, .min, .rem => 2,
                .abs, .puts => 1,
            };
            if (argc != want) return self.reject(
                loc,
                "`{s}` takes {d} argument(s); this call passes {d}.",
                .{ name, want, argc },
                "Run this file with the interpreter.",
            );
            return .{ .builtin = b };
        }
        return self.reject(
            loc,
            "There is no `{s}` in compiled code: it is not a def in this file, and not one of the builtins the compiler provides ({s}).",
            .{ name, builtin_list },
            "The interpreter's other builtins are not compiled yet. Run this file with the interpreter.",
        );
    }

    /// What each argument may be.  A compiled def binds every parameter as
    /// an i64 Int, so it can be passed an Int, or an actor (an i64 id, which
    /// `c <- :get` in the body sends to).  The builtins take what they are
    /// compiled for below.  Anything else used to be passed as it was to a
    /// function declared to take i64: a String was a pointer and LLVM
    /// refused it, a Float would have been reinterpreted.
    fn requireArgTags(self: *Codegen, name: []const u8, callee: Callee, args: []const TaggedVal, locs: []const ast.Loc) CodegenError!void {
        const allowed: []const ValTag, const what: []const u8 = switch (callee) {
            .def => .{ &.{ .int, .actor_ref }, "an Int or an actor" },
            // compileFnExpr unwraps every parameter with blimp_val_to_int.
            .closure => .{ &.{.int}, "an Int" },
            .builtin => |b| switch (b) {
                .max, .min, .rem => .{ &.{.int}, "an Int" },
                .abs => .{ &.{ .int, .float }, "an Int or a Float" },
                .puts => .{ &.{ .int, .float, .string, .boolean }, "an Int, a Float, a String or a Bool" },
            },
        };
        for (args, 0..) |a, i| {
            if (std.mem.indexOfScalar(ValTag, allowed, a.tag) != null) continue;
            return self.reject(
                locs[i],
                "Argument {d} of `{s}` is {s}; compiled code can pass it only {s}.",
                .{ i + 1, name, tagNoun(a.tag), what },
                "Run this file with the interpreter.",
            );
        }
    }

    fn tagNoun(tag: ValTag) []const u8 {
        return switch (tag) {
            .int => "an Int",
            .float => "a Float",
            .boolean => "a Bool",
            .string => "a String",
            .atom => "an Atom",
            .nil => "nil",
            .actor_ref => "an actor",
            .tagged_val => "a list, map or fn value",
        };
    }

    fn emitCall(self: *Codegen, name: []const u8, call_loc: ast.Loc, callee: Callee, args: []const TaggedVal, locs: []const ast.Loc) CodegenError!TaggedVal {
        try self.requireArgTags(name, callee, args, locs);
        switch (callee) {
            .builtin => |b| switch (b) {
                // icmp + select
                .max, .min => {
                    const pred: c_uint = if (b == .max) c.LLVMIntSGT else c.LLVMIntSLT;
                    const cmp = c.LLVMBuildICmp(self.builder, pred, args[0].val, args[1].val, "cmptmp");
                    return .{ .val = c.LLVMBuildSelect(self.builder, cmp, args[0].val, args[1].val, self.zname(name)), .tag = .int };
                },
                .rem => return self.emitRem(args[0].val, args[1].val, call_loc),
                .abs => return self.emitAbs(args[0]),
                .puts => return self.emitPuts(args[0]),
            },
            .closure => |entry| return self.emitClosureCall(name, call_loc, entry, args),
            .def => {
                // Declared by forwardDeclareDefs or compileDef before any call.
                const func = c.LLVMGetNamedFunction(self.module, self.defSymbol(name));
                if (func == null) return CodegenError.LLVMError;
                const ft = c.LLVMGlobalGetValueType(func);
                const vals = self.allocator.alloc(c.LLVMValueRef, args.len) catch return CodegenError.LLVMError;
                for (args, 0..) |a, i| vals[i] = a.val;
                const val = c.LLVMBuildCall2(self.builder, ft, func, vals.ptr, @intCast(vals.len), "calltmp");
                // Mark as tail call if this is a recursive call to the current def
                if (self.tail_call_target) |target| {
                    if (std.mem.eql(u8, name, target)) c.LLVMSetTailCall(val, 1);
                }
                return .{ .val = val, .tag = .int };
            },
        }
    }

    /// rem(a, b): the interpreter's @rem.  A zero divisor is its
    /// DivisionByZero: caught by `try` as :division_by_zero and passed over
    /// by `orelse`, like `a / 0`, but reported uncaught in the interpreter's
    /// words for an error out of a builtin.  rem(minInt, -1) is
    /// 0 there; LLVM's srem of those two is undefined behaviour, so a
    /// divisor of -1 is replaced by 1, which has the same remainder (0).
    fn emitRem(self: *Codegen, a: c.LLVMValueRef, b: c.LLVMValueRef, loc: ast.Loc) TaggedVal {
        const zero = c.LLVMConstInt(self.i64_type, 0, 0);
        self.emitZeroCheck(c.LLVMBuildICmp(self.builder, c.LLVMIntEQ, b, zero, "rem0"), loc, "blimp_raise_rem_zero");
        const minus_one = c.LLVMConstInt(self.i64_type, @bitCast(@as(i64, -1)), 1);
        const is_m1 = c.LLVMBuildICmp(self.builder, c.LLVMIntEQ, b, minus_one, "rem_m1");
        const safe_b = c.LLVMBuildSelect(self.builder, is_m1, c.LLVMConstInt(self.i64_type, 1, 0), b, "rem_b");
        return .{ .val = c.LLVMBuildSRem(self.builder, a, safe_b, "remtmp"), .tag = .int };
    }

    /// abs(n): an Int wraps at minInt (0 -% n, as the interpreter does; no
    /// nsw on the sub), a Float drops its sign.  This used to be libc's
    /// `int abs(int)`, which truncated 5000000000 to 705032704.
    fn emitAbs(self: *Codegen, n: TaggedVal) TaggedVal {
        if (n.tag == .float) {
            const neg = c.LLVMBuildFCmp(self.builder, c.LLVMRealOLT, n.val, c.LLVMConstReal(self.f64_type, 0.0), "fabs_neg");
            const flipped = c.LLVMBuildFNeg(self.builder, n.val, "fabs_flip");
            return .{ .val = c.LLVMBuildSelect(self.builder, neg, flipped, n.val, "fabs"), .tag = .float };
        }
        const zero = c.LLVMConstInt(self.i64_type, 0, 0);
        const neg = c.LLVMBuildICmp(self.builder, c.LLVMIntSLT, n.val, zero, "abs_neg");
        const flipped = c.LLVMBuildSub(self.builder, zero, n.val, "abs_flip");
        return .{ .val = c.LLVMBuildSelect(self.builder, neg, flipped, n.val, "abs"), .tag = .int };
    }

    /// puts(x): the interpreter writes a String's bytes as they are and any
    /// other value formatted, then a newline, and returns x.  An Int, a
    /// Float and a Bool format the same either side; other tags are
    /// refused in requireArgTags.
    fn emitPuts(self: *Codegen, x: TaggedVal) TaggedVal {
        if (x.tag == .string) {
            const f = self.getRuntimeFn("blimp_puts_string", &.{self.ptr_type}, self.void_type);
            var pt = [_]c.LLVMTypeRef{self.ptr_type};
            var args = [_]c.LLVMValueRef{x.val};
            _ = c.LLVMBuildCall2(self.builder, c.LLVMFunctionType(self.void_type, &pt, 1, 0), f, &args, 1, "");
        } else {
            self.emitPrint(x);
        }
        return x;
    }

    /// `f(21)` where f holds a value.  The runtime checks it is a closure
    /// taking that many arguments (UNKNOWN FUNCTION or WRONG ARGUMENT COUNT
    /// and exit 1 otherwise, as the interpreter reports them) and hands back
    /// its function, BlimpVal *(BlimpVal *, ...): each Int is boxed, the
    /// result unboxed.  compileFnExpr makes sure that result is an Int.
    fn emitClosureCall(self: *Codegen, name: []const u8, loc: ast.Loc, entry: Scope.Entry, args: []const TaggedVal) CodegenError!TaggedVal {
        const n: u32 = @intCast(args.len);
        const v = c.LLVMBuildLoad2(self.builder, entry.llvm_type, entry.alloca, self.zname(name));
        const check = self.getRuntimeFn("blimp_closure_fn", &.{ self.ptr_type, self.i32_type, self.ptr_type, self.ptr_type }, self.ptr_type);
        var cpt = [_]c.LLVMTypeRef{ self.ptr_type, self.i32_type, self.ptr_type, self.ptr_type };
        var cargs = [_]c.LLVMValueRef{
            v,
            c.LLVMConstInt(self.i32_type, n, 0),
            c.LLVMBuildGlobalStringPtr(self.builder, self.zname(name), "callee_name"),
            self.siteGlobal(loc),
        };
        const fp = c.LLVMBuildCall2(self.builder, c.LLVMFunctionType(self.ptr_type, &cpt, 4, 0), check, &cargs, 4, "closure_fn");

        const box = self.getRuntimeFn("blimp_val_int", &.{self.i64_type}, self.ptr_type);
        var bpt = [_]c.LLVMTypeRef{self.i64_type};
        const box_ft = c.LLVMFunctionType(self.ptr_type, &bpt, 1, 0);
        const vals = self.allocator.alloc(c.LLVMValueRef, n) catch return CodegenError.LLVMError;
        const tys = self.allocator.alloc(c.LLVMTypeRef, n) catch return CodegenError.LLVMError;
        for (args, 0..) |a, i| {
            var one = [_]c.LLVMValueRef{a.val};
            vals[i] = c.LLVMBuildCall2(self.builder, box_ft, box, &one, 1, "arg_box");
            tys[i] = self.ptr_type;
        }
        const ft = c.LLVMFunctionType(self.ptr_type, tys.ptr, n, 0);
        const boxed = c.LLVMBuildCall2(self.builder, ft, fp, vals.ptr, n, "closure_ret");

        const unbox = self.getRuntimeFn("blimp_val_to_int", &.{self.ptr_type}, self.i64_type);
        var upt = [_]c.LLVMTypeRef{self.ptr_type};
        var uargs = [_]c.LLVMValueRef{boxed};
        const val = c.LLVMBuildCall2(self.builder, c.LLVMFunctionType(self.i64_type, &upt, 1, 0), unbox, &uargs, 1, "closure_int");
        return .{ .val = val, .tag = .int };
    }

    fn compileFuncCall(self: *Codegen, call: ast.Node.FuncCall, loc: ast.Loc) CodegenError!TaggedVal {
        try self.checkDefCallCatchable(call.name);
        const callee = try self.resolveCallee(call.name, loc, call.args.len);
        const args = self.allocator.alloc(TaggedVal, call.args.len) catch return CodegenError.LLVMError;
        const locs = self.allocator.alloc(ast.Loc, call.args.len) catch return CodegenError.LLVMError;
        for (call.args, 0..) |arg, i| {
            args[i] = try self.compileExpr(arg);
            locs[i] = arg.loc;
        }
        return self.emitCall(call.name, loc, callee, args, locs);
    }

    /// `x |> f(a, _)` passes x where the hole is; `x |> f(a)` passes it
    /// first; `x |> f` passes it alone.  Then it is a call like any other.
    fn compilePipe(self: *Codegen, pipe: ast.Node.PipeExpr) CodegenError!TaggedVal {
        const right = pipe.right.*;
        const name: []const u8, const call_args: []const ast.Node = switch (right.kind) {
            .func_call => |call| .{ call.name, call.args },
            .identifier => |id| .{ id.name, &.{} },
            else => return CodegenError.UnsupportedNode,
        };
        try self.checkDefCallCatchable(name);

        var holes: usize = 0;
        for (call_args) |a| if (a.kind == .hole) {
            holes += 1;
        };
        const argc = if (holes > 0) call_args.len else call_args.len + 1;
        const callee = try self.resolveCallee(name, right.loc, argc);

        const left_val = try self.compileExpr(pipe.left.*);
        const args = self.allocator.alloc(TaggedVal, argc) catch return CodegenError.LLVMError;
        const locs = self.allocator.alloc(ast.Loc, argc) catch return CodegenError.LLVMError;
        var n: usize = 0;
        if (holes == 0) {
            args[0] = left_val;
            locs[0] = pipe.left.loc;
            n = 1;
        }
        for (call_args) |a| {
            if (a.kind == .hole) {
                args[n] = left_val;
                locs[n] = pipe.left.loc;
            } else {
                args[n] = try self.compileExpr(a);
                locs[n] = a.loc;
            }
            n += 1;
        }
        return self.emitCall(name, right.loc, callee, args, locs);
    }

    fn compileBinaryOp(self: *Codegen, op: ast.Node.BinaryOp, loc: ast.Loc) CodegenError!TaggedVal {
        if (op.op == .and_op or op.op == .or_op) return self.compileLogical(op);
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
            if (op.op == .div) {
                const zero = c.LLVMConstReal(self.f64_type, 0.0);
                self.emitDivZeroCheck(c.LLVMBuildFCmp(self.builder, c.LLVMRealOEQ, fr, zero, "fdiv0"), loc);
            }

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
            // A comparison is a Bool (an i64 0 or 1), arithmetic a Float.
            const tag: ValTag = switch (op.op) {
                .lt, .gt, .lte, .gte, .eq, .neq => .boolean,
                else => .float,
            };
            return .{ .val = val, .tag = tag };
        }

        // Integer path.  `sdiv` by zero is undefined behaviour in LLVM, and
        // at O3 it came out as 1 for 10 / 0: check first, as the interpreter does.
        if (op.op == .div) {
            const zero = c.LLVMConstInt(self.i64_type, 0, 0);
            self.emitDivZeroCheck(c.LLVMBuildICmp(self.builder, c.LLVMIntEQ, rhs.val, zero, "div0"), loc);
        }
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
            .and_op, .or_op => unreachable, // compileLogical
            .concat => return CodegenError.UnsupportedNode, // ++ needs tagged values
        };
        const tag: ValTag = switch (op.op) {
            .eq, .neq, .lt, .gt, .lte, .gte => .boolean,
            else => .int,
        };
        return .{ .val = val, .tag = tag };
    }

    /// `a && b`, `a || b`: the interpreter stops at the left side when it
    /// decides the answer, so the right side runs only when it must (a send
    /// or a division on the right is not evaluated), and the result is a
    /// Bool.  Both sides must be Bools here: the interpreter's truthiness
    /// counts an Int 0 as true, and an i64 compared with 0 would not.
    fn compileLogical(self: *Codegen, op: ast.Node.BinaryOp) CodegenError!TaggedVal {
        const func = self.current_fn orelse return CodegenError.LLVMError;
        const sym = if (op.op == .and_op) "&&" else "||";
        const lhs = try self.compileExpr(op.left.*);
        if (lhs.tag != .boolean) return self.rejectLogicalSide(op.left.loc, sym, lhs.tag);
        const lhs_end = c.LLVMGetInsertBlock(self.builder);
        const rhs_bb = c.LLVMAppendBasicBlockInContext(self.context, func, "logic_rhs");
        const merge_bb = c.LLVMAppendBasicBlockInContext(self.context, func, "logic_merge");
        const is_true = c.LLVMBuildICmp(self.builder, c.LLVMIntNE, lhs.val, c.LLVMConstInt(self.i64_type, 0, 0), "lhs_true");
        if (op.op == .and_op)
            _ = c.LLVMBuildCondBr(self.builder, is_true, rhs_bb, merge_bb)
        else
            _ = c.LLVMBuildCondBr(self.builder, is_true, merge_bb, rhs_bb);

        c.LLVMPositionBuilderAtEnd(self.builder, rhs_bb);
        const rhs = try self.compileExpr(op.right.*);
        if (rhs.tag != .boolean) return self.rejectLogicalSide(op.right.loc, sym, rhs.tag);
        const rhs_end = c.LLVMGetInsertBlock(self.builder);
        _ = c.LLVMBuildBr(self.builder, merge_bb);

        c.LLVMPositionBuilderAtEnd(self.builder, merge_bb);
        const phi = c.LLVMBuildPhi(self.builder, self.i64_type, "logic");
        var vals = [_]c.LLVMValueRef{ c.LLVMConstInt(self.i64_type, if (op.op == .and_op) 0 else 1, 0), rhs.val };
        var blocks = [_]c.LLVMBasicBlockRef{ lhs_end, rhs_end };
        c.LLVMAddIncoming(phi, &vals, &blocks, 2);
        return .{ .val = phi, .tag = .boolean };
    }

    fn rejectLogicalSide(self: *Codegen, loc: ast.Loc, sym: []const u8, tag: ValTag) CodegenError {
        return self.reject(
            loc,
            "This side of `{s}` is {s}; compiled code takes only a Bool here.",
            .{ sym, tagNoun(tag) },
            "Run this file with the interpreter.",
        );
    }

    fn compileUnaryOp(self: *Codegen, op: ast.Node.UnaryOp) CodegenError!TaggedVal {
        const operand = try self.compileExpr(op.operand.*);
        const val = switch (op.op) {
            .negate => if (operand.tag == .float)
                c.LLVMBuildFNeg(self.builder, operand.val, "fnegtmp")
            else
                c.LLVMBuildNeg(self.builder, operand.val, "negtmp"),
            .not => blk: {
                if (operand.tag != .boolean) return self.reject(
                    op.operand.loc,
                    "`!` of {s}; compiled code takes only a Bool here.",
                    .{tagNoun(operand.tag)},
                    "Run this file with the interpreter.",
                );
                const zero = c.LLVMConstInt(self.i64_type, 0, 0);
                const cmp_val = c.LLVMBuildICmp(self.builder, c.LLVMIntEQ, operand.val, zero, "nottmp");
                break :blk c.LLVMBuildZExt(self.builder, cmp_val, self.i64_type, "notext");
            },
        };
        return .{ .val = val, .tag = if (op.op == .not) .boolean else operand.tag };
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
        const saved_bb = c.LLVMGetInsertBlock(self.builder);
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
                        // TODO: a default the compiler cannot build silently becomes 0.
                        const dv_result = self.compileExpr(dv.*) catch {
                            self.failure = null;
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

        // Restore builder to where main was.  Not its last block: a send's
        // raise path or an orelse appends blocks that are not where main
        // carries on.
        if (saved_fn != null and saved_bb != null) {
            c.LLVMPositionBuilderAtEnd(self.builder, saved_bb);
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

        const saved_kind = self.fn_kind;
        const saved_catches = self.catches;
        self.fn_kind = .handler;
        self.catches = .empty;
        self.reply_mask = 0;
        self.reply_may_nil = false;
        defer {
            self.catches.deinit(self.allocator);
            self.catches = saved_catches;
            self.fn_kind = saved_kind;
        }
        const param_tags = self.allocator.alloc(?ValTag, handler.params.len) catch return CodegenError.LLVMError;
        for (handler.params, 0..) |param, i| param_tags[i] = self.handlerParamTag(param);

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

            // Every field is stored as an i64; the local holds it as what
            // its tag says (an Atom an i32, a String a ptr), as any other
            // local of that tag does.
            const tag = actor_desc.state_default_tags[i];
            const alloca = c.LLVMBuildAlloca(self.builder, self.llvmTypeForTag(tag), self.zname(field_name));
            _ = c.LLVMBuildStore(self.builder, self.coerceFromI64(loaded, tag), alloca);
            self.scope.put(self.allocator, .{
                .name = field_name,
                .alloca = alloca,
                .tag = tag,
                .llvm_type = self.llvmTypeForTag(tag),
            });
        }

        // Bind handler params
        for (handler.params, 0..) |param, i| {
            const param_val = c.LLVMGetParam(func, @intCast(i + 1));
            const tag = param_tags[i] orelse {
                // Kept as its i64 bits: it can be passed on, as it is, to a
                // handler parameter that is not bound either.
                const raw = c.LLVMBuildAlloca(self.builder, self.i64_type, self.zname(param.name));
                _ = c.LLVMBuildStore(self.builder, param_val, raw);
                self.scope.put(self.allocator, .{
                    .name = param.name,
                    .alloca = raw,
                    .tag = .nil,
                    .llvm_type = self.i64_type,
                    .unbound = std.fmt.allocPrint(
                        self.allocator,
                        "Parameter `{s}` of :{s} is typed {s}; a compiled handler binds only Int, Float, Bool, String, Atom or actor parameters.",
                        .{ param.name, handler.name, param.type_name orelse "nothing" },
                    ) catch "unbound parameter",
                });
                continue;
            };
            const alloca = c.LLVMBuildAlloca(self.builder, self.llvmTypeForTag(tag), self.zname(param.name));
            _ = c.LLVMBuildStore(self.builder, self.coerceFromI64(param_val, tag), alloca);
            self.scope.put(self.allocator, .{
                .name = param.name,
                .alloca = alloca,
                .tag = tag,
                .llvm_type = self.llvmTypeForTag(tag),
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

            // Guard fail: the runtime tries the next clause
            c.LLVMPositionBuilderAtEnd(self.builder, fail_bb);
            _ = c.LLVMBuildRet(self.builder, self.makeHandlerRet(Status.nomatch, c.LLVMConstInt(self.i64_type, 0, 0)));

            c.LLVMPositionBuilderAtEnd(self.builder, body_bb);
        }

        // Compile handler body
        var last_val: TaggedVal = .{ .val = c.LLVMConstInt(self.i64_type, 0, 0), .tag = .nil };
        for (handler.body) |stmt| {
            last_val = try self.compileExpr(stmt);
        }

        // Fell off the end without a reply: nil, which `orelse` falls back on
        const current_bb = c.LLVMGetInsertBlock(self.builder);
        if (c.LLVMGetBasicBlockTerminator(current_bb) == null) {
            _ = c.LLVMBuildRet(self.builder, self.makeHandlerRet(Status.nil, c.LLVMConstInt(self.i64_type, 0, 0)));
            // Not when the only way here is past a bubble: `_ -> bubble :bad`
            // leaves the builder in a block nothing can reach.
            if (self.blockReachable(current_bb, entry)) self.reply_may_nil = true;
        }

        // Register handler
        const atom_id = self.atoms.intern(self.allocator, handler.name);
        actor_desc.handler_fns.append(self.allocator, .{
            .name = handler.name,
            .atom_id = atom_id,
            .func = func,
            .param_count = param_count,
            .param_tags = param_tags,
            .reply_mask = self.reply_mask,
            .may_nil = self.reply_may_nil,
        }) catch {};
    }

    /// A handler parameter is bound from an i64 argument slot, so the
    /// compiler has to know what it holds: its annotation says.  Without
    /// one it was bound as an Int, and a String argument printed as the
    /// address it was.
    fn handlerParamTag(self: *Codegen, param: ast.Node.HandlerParam) ?ValTag {
        switch (param.check) {
            .int => return .int,
            .float => return .float,
            .string => return .string,
            .atom => return .atom,
            .boolean => return .boolean,
            .named => for (self.actor_names.items) |n| {
                if (std.mem.eql(u8, n, param.type_name.?)) return .actor_ref;
            },
            else => {},
        }
        return null;
    }

    /// Whether any path from `entry` reaches `bb`, walking predecessors
    /// (the terminators that use the block).  A block emitRaise or a dead
    /// merge leaves behind has none that are reachable.
    fn blockReachable(self: *Codegen, bb: c.LLVMBasicBlockRef, entry: c.LLVMBasicBlockRef) bool {
        var seen: std.ArrayList(c.LLVMBasicBlockRef) = .empty;
        defer seen.deinit(self.allocator);
        var work: std.ArrayList(c.LLVMBasicBlockRef) = .empty;
        defer work.deinit(self.allocator);
        work.append(self.allocator, bb) catch return true;
        while (work.pop()) |b| {
            if (b == entry) return true;
            if (std.mem.indexOfScalar(c.LLVMBasicBlockRef, seen.items, b) != null) continue;
            seen.append(self.allocator, b) catch return true;
            var use = c.LLVMGetFirstUse(c.LLVMBasicBlockAsValue(b));
            while (use != null) : (use = c.LLVMGetNextUse(use)) {
                const user = c.LLVMGetUser(use);
                if (c.LLVMIsATerminatorInst(user) == null) continue;
                work.append(self.allocator, c.LLVMGetInstructionParent(user)) catch return true;
            }
        }
        return false;
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
                    try self.requireFieldTag(field.key, actor.state_default_tags[i], new_val.tag, field.value.loc);
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

    /// A field is one i64 slot with one tag, the tag of its default: the
    /// handlers read it back as that.  A value of another tag stored in it
    /// would be read back as the wrong type, so it is refused.
    fn requireFieldTag(self: *Codegen, field: []const u8, want: ValTag, got: ValTag, loc: ast.Loc) CodegenError!void {
        if (want == got) return;
        return self.reject(
            loc,
            "State field `{s}` holds {s} in compiled code (its default), and this is {s}.",
            .{ field, tagNoun(want), tagNoun(got) },
            "Run this file with the interpreter.",
        );
    }

    fn compileReply(self: *Codegen, reply: ast.Node.ReplyStmt) CodegenError!TaggedVal {
        const val = try self.compileExpr(reply.value.*);
        if (val.tag == .tagged_val) return self.reject(
            reply.value.loc,
            "A compiled reply can be an Int, a Float, a Bool, a String, an Atom, an actor or nil; this is {s}.",
            .{tagNoun(val.tag)},
            "Run this file with the interpreter.",
        );
        if (val.tag == .nil) self.reply_may_nil = true else self.reply_mask |= tagBit(val.tag);
        // Coerce to i64 for the {i1, i64} handler return type
        const ret_val = self.coerceToI64(val);
        const status = if (val.tag == .nil) Status.nil else Status.ok;
        _ = c.LLVMBuildRet(self.builder, self.makeHandlerRet(status, ret_val));
        return val;
    }

    /// Build a {i8 status, i64 value} struct value for handler returns.
    fn makeHandlerRet(self: *Codegen, status: u64, value: c.LLVMValueRef) c.LLVMValueRef {
        return self.makeHandlerRetDyn(c.LLVMConstInt(self.i8_type, status, 0), value);
    }

    fn makeHandlerRetDyn(self: *Codegen, status: c.LLVMValueRef, value: c.LLVMValueRef) c.LLVMValueRef {
        const undef = c.LLVMGetUndef(self.handler_ret_type);
        const with_flag = c.LLVMBuildInsertValue(self.builder, undef, status, 0, "ret_status");
        return c.LLVMBuildInsertValue(self.builder, with_flag, value, 1, "ret_val");
    }

    // ── Raising: bubbles and runtime errors ─────────────────

    /// A constant BlimpSite {line, col, source line} for a report at `loc`.
    fn siteGlobal(self: *Codegen, loc: ast.Loc) c.LLVMValueRef {
        const text: []const u8 = if (loc.line == 0 or self.source.len == 0) "" else errors.lineAt(self.source, loc.line);
        const str = c.LLVMBuildGlobalStringPtr(self.builder, self.zname(text), "site_src");
        var fields = [_]c.LLVMValueRef{
            c.LLVMConstInt(self.i32_type, loc.line, 0),
            c.LLVMConstInt(self.i32_type, loc.col, 0),
            str,
        };
        const g = c.LLVMAddGlobal(self.module, self.site_type, "site");
        c.LLVMSetInitializer(g, c.LLVMConstStructInContext(self.context, &fields, 3, 0));
        c.LLVMSetGlobalConstant(g, 1);
        c.LLVMSetLinkage(g, c.LLVMPrivateLinkage);
        return g;
    }

    /// Send a raise (status `bubble` or `fault`, a BlimpRaise*) to whoever
    /// takes it, from a block that has not been terminated:
    ///   the innermost enclosing try takes anything; an orelse only bubbles;
    ///   with neither, a handler returns it to its sender, and main or a def
    ///   reports it and exits 1, which is what the interpreter does when a
    ///   bubble reaches the top.
    /// Leaves the builder in a fresh block with no predecessors.
    fn emitRaise(self: *Codegen, status: c.LLVMValueRef, raise_ptr: c.LLVMValueRef) void {
        const func = self.current_fn.?;
        var i = self.catches.items.len;
        const delivered = blk: while (i > 0) {
            i -= 1;
            const k = self.catches.items[i];
            switch (k.kind) {
                .try_ => {
                    _ = c.LLVMBuildStore(self.builder, raise_ptr, k.slot);
                    _ = c.LLVMBuildBr(self.builder, k.landing);
                    break :blk true;
                },
                .orelse_ => {
                    const is_bubble = c.LLVMBuildICmp(self.builder, c.LLVMIntEQ, status, c.LLVMConstInt(self.i8_type, Status.bubble, 0), "is_bubble");
                    const past = c.LLVMAppendBasicBlockInContext(self.context, func, "fault_past_orelse");
                    _ = c.LLVMBuildCondBr(self.builder, is_bubble, k.landing, past);
                    c.LLVMPositionBuilderAtEnd(self.builder, past);
                },
            }
        } else false;

        if (!delivered) switch (self.fn_kind) {
            .handler => {
                const as_int = c.LLVMBuildPtrToInt(self.builder, raise_ptr, self.i64_type, "raise_int");
                _ = c.LLVMBuildRet(self.builder, self.makeHandlerRetDyn(status, as_int));
            },
            .main, .def => {
                const f = self.getRuntimeFn("blimp_uncaught", &.{self.ptr_type}, self.void_type);
                var args = [_]c.LLVMValueRef{raise_ptr};
                var pt = [_]c.LLVMTypeRef{self.ptr_type};
                _ = c.LLVMBuildCall2(self.builder, c.LLVMFunctionType(self.void_type, &pt, 1, 0), f, &args, 1, "");
                _ = c.LLVMBuildUnreachable(self.builder);
            },
        };

        const after = c.LLVMAppendBasicBlockInContext(self.context, func, "after_raise");
        c.LLVMPositionBuilderAtEnd(self.builder, after);
    }

    /// Branch on a {status, value} result from a send: a bubble or fault goes
    /// to `emitRaise`, anything else continues with the value.
    fn emitCheckResult(self: *Codegen, result: c.LLVMValueRef) struct { val: c.LLVMValueRef, status: c.LLVMValueRef } {
        const func = self.current_fn.?;
        const status = c.LLVMBuildExtractValue(self.builder, result, 0, "status");
        const val = c.LLVMBuildExtractValue(self.builder, result, 1, "value");
        const raised = c.LLVMBuildICmp(self.builder, c.LLVMIntUGE, status, c.LLVMConstInt(self.i8_type, Status.bubble, 0), "raised");
        const raise_bb = c.LLVMAppendBasicBlockInContext(self.context, func, "raised");
        const ok_bb = c.LLVMAppendBasicBlockInContext(self.context, func, "replied");
        _ = c.LLVMBuildCondBr(self.builder, raised, raise_bb, ok_bb);
        c.LLVMPositionBuilderAtEnd(self.builder, raise_bb);
        self.emitRaise(status, c.LLVMBuildIntToPtr(self.builder, val, self.ptr_type, "raise_ptr"));
        // emitRaise left us in an unreachable block; nothing goes there.
        _ = c.LLVMBuildUnreachable(self.builder);
        c.LLVMPositionBuilderAtEnd(self.builder, ok_bb);
        return .{ .val = val, .status = status };
    }

    /// `a / b` with b == 0: a fault at the operator, as the interpreter's
    /// DIVISION BY ZERO.  Leaves the builder where b != 0.
    fn emitDivZeroCheck(self: *Codegen, is_zero: c.LLVMValueRef, loc: ast.Loc) void {
        self.emitZeroCheck(is_zero, loc, "blimp_raise_div_zero");
    }

    /// The same fault, raised by `raise_fn` (a BlimpRaise *(const BlimpSite *)).
    fn emitZeroCheck(self: *Codegen, is_zero: c.LLVMValueRef, loc: ast.Loc, raise_fn: [*:0]const u8) void {
        const func = self.current_fn orelse return;
        _ = self.atoms.intern(self.allocator, "division_by_zero"); // what `catch e` binds
        const zero_bb = c.LLVMAppendBasicBlockInContext(self.context, func, "div_by_zero");
        const ok_bb = c.LLVMAppendBasicBlockInContext(self.context, func, "div_ok");
        _ = c.LLVMBuildCondBr(self.builder, is_zero, zero_bb, ok_bb);
        c.LLVMPositionBuilderAtEnd(self.builder, zero_bb);
        const f = self.getRuntimeFn(raise_fn, &.{self.ptr_type}, self.ptr_type);
        var args = [_]c.LLVMValueRef{self.siteGlobal(loc)};
        var pt = [_]c.LLVMTypeRef{self.ptr_type};
        const raise_ptr = c.LLVMBuildCall2(self.builder, c.LLVMFunctionType(self.ptr_type, &pt, 1, 0), f, &args, 1, "div_zero");
        self.emitRaise(c.LLVMConstInt(self.i8_type, Status.fault, 0), raise_ptr);
        _ = c.LLVMBuildUnreachable(self.builder);
        c.LLVMPositionBuilderAtEnd(self.builder, ok_bb);
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
                    // TODO: an override the compiler cannot build silently keeps the default.
                    value = self.compileExpr(ov.value) catch {
                        self.failure = null;
                        break;
                    };
                    try self.requireFieldTag(field_name, actor.state_default_tags[i], value.tag, ov.value.loc);
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
        } else {
            // The runtime names the actor in NO MATCHING HANDLER.
            const type_str = c.LLVMBuildGlobalStringPtr(self.builder, self.zname(actor.name), "type_name");
            const set_type_fn = self.getRuntimeFn("blimp_set_actor_type", &.{ self.i32_type, self.ptr_type }, self.void_type);
            var type_args = [_]c.LLVMValueRef{ actor_id, type_str };
            var type_pt = [_]c.LLVMTypeRef{ self.i32_type, self.ptr_type };
            _ = c.LLVMBuildCall2(self.builder, c.LLVMFunctionType(self.void_type, &type_pt, 2, 0), set_type_fn, &type_args, 2, "");
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

    /// Bubble: box the reason, record where, and raise.  It used to return
    /// {matched, 0}, the same as `reply 0`: the sender got 0, `orelse` could
    /// not tell it from a real reply of 0, and one nothing caught printed a
    /// plausible number and exited 0.
    fn compileBubble(self: *Codegen, bs: ast.Node.BubbleStmt, loc: ast.Loc) CodegenError!TaggedVal {
        if (self.fn_kind == .def) {
            return self.reject(
                loc,
                "`bubble` inside `{s}` cannot be compiled: a def returns a bare value, so the reason would have nowhere to go.",
                .{self.current_def_name},
                "Move the bubble into an actor handler, or run this file with the interpreter.",
            );
        }
        if (self.fn_kind == .handler) {
            const actor = self.current_actor.?.name;
            // The interpreter restarts a dotted actor (or its siblings) under
            // its supervisor when it bubbles.  Compiled actors have none.
            if (std.mem.lastIndexOfScalar(u8, actor, '.')) |dot| {
                return self.reject(
                    loc,
                    "`bubble` in a handler of `{s}` restarts it under its supervisor `{s}`; compiled actors have no supervisor, so the restart would not happen.",
                    .{ actor, actor[0..dot] },
                    "Run this file with the interpreter, which supervises.",
                );
            }
        }

        const reason_ptr = if (bs.reason) |reason|
            self.wrapAsBlimpVal(try self.compileExpr(reason.*))
        else blk: {
            _ = self.atoms.intern(self.allocator, "bubble"); // what `catch e` binds
            break :blk c.LLVMConstNull(self.ptr_type);
        };
        const f = self.getRuntimeFn("blimp_raise_bubble", &.{ self.ptr_type, self.ptr_type }, self.ptr_type);
        var args = [_]c.LLVMValueRef{ reason_ptr, self.siteGlobal(loc) };
        var pt = [_]c.LLVMTypeRef{ self.ptr_type, self.ptr_type };
        const raise_ptr = c.LLVMBuildCall2(self.builder, c.LLVMFunctionType(self.ptr_type, &pt, 2, 0), f, &args, 2, "bubble");
        self.emitRaise(c.LLVMConstInt(self.i8_type, Status.bubble, 0), raise_ptr);
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
        const saved_bb = c.LLVMGetInsertBlock(self.builder);
        const saved_kind = self.fn_kind;
        const saved_def_name = self.current_def_name;
        const saved_catches = self.catches;
        self.fn_kind = .def;
        self.current_def_name = std.fmt.allocPrint(self.allocator, "def {s}", .{ds.name}) catch ds.name;
        self.catches = .empty;
        defer {
            self.catches.deinit(self.allocator);
            self.catches = saved_catches;
            self.fn_kind = saved_kind;
            self.current_def_name = saved_def_name;
        }
        self.scope = .{};
        if (self.findDef(ds.name) == null) self.defs.append(self.allocator, ds) catch return CodegenError.LLVMError;

        // Create function: i64 name(i64, i64, ...)
        const param_count: u32 = @intCast(ds.params.len);
        var param_types = self.allocator.alloc(c.LLVMTypeRef, param_count) catch return CodegenError.LLVMError;
        for (0..param_count) |i| {
            param_types[i] = self.i64_type;
        }
        const fn_type = c.LLVMFunctionType(self.i64_type, param_types.ptr, param_count, 0);

        // Use existing forward declaration if present, otherwise create
        const func = c.LLVMGetNamedFunction(self.module, self.defSymbol(ds.name)) orelse
            self.addDefFunction(ds.name, fn_type);

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

        // Position builder back where the calling function was
        if (saved_fn != null and saved_bb != null) {
            c.LLVMPositionBuilderAtEnd(self.builder, saved_bb);
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

    fn compileFnExpr(self: *Codegen, fe: ast.Node.FnExpr, loc: ast.Loc) CodegenError!TaggedVal {
        // Create an LLVM function for the closure body
        const cur_fn = self.current_fn;
        const saved_scope = self.scope;
        const saved_bb = c.LLVMGetInsertBlock(self.builder);
        const saved_kind = self.fn_kind;
        const saved_def_name = self.current_def_name;
        const saved_catches = self.catches;
        // A closure is called by the runtime and returns a bare BlimpVal*:
        // it has no channel for a bubble either.
        self.fn_kind = .def;
        self.current_def_name = "fn";
        self.catches = .empty;
        defer {
            self.catches.deinit(self.allocator);
            self.catches = saved_catches;
            self.fn_kind = saved_kind;
            self.current_def_name = saved_def_name;
        }
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

        // The body's value is boxed as an Int.  Anything else was boxed as
        // one too (a Bool as 1, nil as 0) or failed verification (a pointer).
        if (last_tv.tag != .int) return self.reject(
            if (fe.body.len > 0) fe.body[fe.body.len - 1].loc else loc,
            "This fn returns {s}; a compiled fn can return only an Int.",
            .{tagNoun(last_tv.tag)},
            "Run this file with the interpreter.",
        );
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

        // Position builder back where the calling function was
        if (cur_fn != null and saved_bb != null) {
            c.LLVMPositionBuilderAtEnd(self.builder, saved_bb);
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

    fn compileMessageSend(self: *Codegen, msg: ast.Node.MessageSend, loc: ast.Loc) CodegenError!TaggedVal {
        const under_orelse = self.send_under_orelse;
        self.send_under_orelse = false;
        const target = try self.compileExpr(msg.target.*);
        const arg_tags = self.allocator.alloc(?ValTag, msg.args.len) catch return CodegenError.LLVMError;
        const arg_locs = self.allocator.alloc(ast.Loc, msg.args.len) catch return CodegenError.LLVMError;

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
            arg_locs[i] = arg.loc;
            // Each slot is an i64: an Atom (i32) used to be stored as 4
            // bytes into 8, a String as its pointer.
            const store_val = if (self.unboundArg(arg)) |raw| blk: {
                arg_tags[i] = null;
                break :blk raw;
            } else blk: {
                const arg_val = try self.compileExpr(arg);
                arg_tags[i] = arg_val.tag;
                break :blk self.coerceToI64(arg_val);
            };
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

        // blimp_send(actor_id, handler_atom_id, arg_count, args_ptr, site)
        //   -> {i8 status, i64 value}
        // The site is where a NO MATCHING HANDLER is reported.
        _ = self.atoms.intern(self.allocator, "undefined"); // what `catch e` binds for one
        const send_fn = self.getRuntimeFn(
            "blimp_send",
            &.{ self.i32_type, self.i32_type, self.i32_type, self.ptr_type, self.ptr_type },
            self.handler_ret_type,
        );
        var send_args = [_]c.LLVMValueRef{
            actor_id,
            c.LLVMConstInt(self.i32_type, msg_atom_id, 0),
            c.LLVMConstInt(self.i32_type, arg_count, 0),
            args_alloca,
            self.siteGlobal(loc),
        };
        var send_pt = [_]c.LLVMTypeRef{ self.i32_type, self.i32_type, self.i32_type, self.ptr_type, self.ptr_type };
        const send_ft = c.LLVMFunctionType(self.handler_ret_type, &send_pt, 5, 0);
        const result = c.LLVMBuildCall2(self.builder, send_ft, send_fn, &send_args, 5, "send");
        const checked = self.emitCheckResult(result);
        self.last_send_status = checked.status;
        const reply = try self.replyTag(msg.message, loc, under_orelse);
        const never = self.sendNeverReturns(msg.message);
        self.last_send_never = never;
        self.sends.append(self.allocator, .{
            .message = msg.message,
            .loc = loc,
            .under_orelse = under_orelse,
            .reply = reply,
            .never = never,
            .arg_tags = arg_tags,
            .arg_locs = arg_locs,
        }) catch return CodegenError.LLVMError;
        return .{ .val = self.coerceFromI64(checked.val, reply), .tag = reply };
    }

    /// A send argument that is an unbound handler parameter, by itself:
    /// its i64 bits, passed on without being read as any type.
    fn unboundArg(self: *Codegen, arg: ast.Node) ?c.LLVMValueRef {
        if (arg.kind != .identifier) return null;
        const entry = self.scope.get(arg.kind.identifier.name) orelse return null;
        if (entry.unbound == null) return null;
        return c.LLVMBuildLoad2(self.builder, self.i64_type, entry.alloca, "passed_on");
    }

    /// What a send of `message` hands back, from every handler of that name
    /// compiled so far (the target's actor is not known statically, but
    /// every handler is in this file).  A send is synchronous and returns
    /// one i64, so the tag is static: one tag of reply, or nil when no
    /// handler replies.  A handler that may also end without a reply makes
    /// the result that tag or nil, which one i64 cannot say; that is
    /// compiled only as the left side of an `orelse`, where the status
    /// decides.  Before any handler of that name is compiled the send is
    /// taken to reply an Int, and checkSends holds it to that.
    fn replyTag(self: *Codegen, message: []const u8, loc: ast.Loc, under_orelse: bool) CodegenError!ValTag {
        var mask: u16 = 0;
        var may_nil = false;
        var any = false;
        for (self.actors.items) |a| for (a.handler_fns.items) |h| {
            if (!std.mem.eql(u8, h.name, message)) continue;
            any = true;
            mask |= h.reply_mask;
            may_nil = may_nil or h.may_nil;
        };
        if (!any) return .int;
        // Every handler only raises: the send never hands back a value, so
        // its tag is never read.  Int, as before, so a `try` around it
        // does not box its arms for a value that cannot arrive.
        if (mask == 0 and !may_nil) return .int;
        if (mask == 0) return .nil;
        if (@popCount(mask) > 1) return self.reject(
            loc,
            "Handlers of :{s} reply {s}; a compiled send takes one type of reply.",
            .{ message, self.maskNouns(mask) },
            "Run this file with the interpreter.",
        );
        const tag: ValTag = @enumFromInt(@ctz(mask));
        if (may_nil and !under_orelse) return self.reject(
            loc,
            "A handler of :{s} replies {s} on one path and nothing on another; compiled code can take that only on the left of `orelse`.",
            .{ message, tagNoun(tag) },
            "Reply on every path, put the send before `orelse`, or run this file with the interpreter.",
        );
        return tag;
    }

    /// No handler of `message` compiled so far can end without raising:
    /// there is none (the send is NO MATCHING HANDLER, a fault), or each
    /// one only bubbles.
    fn sendNeverReturns(self: *Codegen, message: []const u8) bool {
        for (self.actors.items) |a| for (a.handler_fns.items) |h| {
            if (!std.mem.eql(u8, h.name, message)) continue;
            if (h.reply_mask != 0 or h.may_nil) return false;
        };
        return true;
    }

    fn maskNouns(self: *Codegen, mask: u16) []const u8 {
        var out: std.ArrayList(u8) = .empty;
        var first = true;
        for (std.enums.values(ValTag)) |t| {
            if (mask & tagBit(t) == 0) continue;
            if (!first) out.appendSlice(self.allocator, " and ") catch {};
            out.appendSlice(self.allocator, tagNoun(t)) catch {};
            first = false;
        }
        return out.items;
    }

    /// Every send again, now that every handler is compiled: its reply must
    /// be what it was compiled for, and each argument what the handlers of
    /// that message bind it as.
    fn checkSends(self: *Codegen) CodegenError!void {
        for (self.sends.items) |snd| {
            const now = try self.replyTag(snd.message, snd.loc, snd.under_orelse);
            var any = false;
            for (self.actors.items) |a| for (a.handler_fns.items) |h| {
                if (!std.mem.eql(u8, h.name, snd.message)) continue;
                any = true;
                if (h.param_count != snd.arg_tags.len) continue;
                for (snd.arg_tags, 0..) |maybe_t, i| {
                    const t = maybe_t orelse {
                        if (h.param_tags[i] == null) continue;
                        return self.reject(
                            snd.arg_locs[i],
                            "Argument {d} of :{s} is a parameter compiled code did not bind; the handler binds it as {s}.",
                            .{ i + 1, snd.message, tagNoun(h.param_tags[i].?) },
                            "Run this file with the interpreter.",
                        );
                    };
                    const want = h.param_tags[i] orelse return self.reject(
                        snd.arg_locs[i],
                        "Argument {d} of :{s} goes to a parameter of a type compiled code does not bind (Int, Float, Bool, String, Atom or an actor).",
                        .{ i + 1, snd.message },
                        "Run this file with the interpreter.",
                    );
                    if (t == want) continue;
                    return self.reject(
                        snd.arg_locs[i],
                        "Argument {d} of :{s} is {s}; the handler binds it as {s}.",
                        .{ i + 1, snd.message, tagNoun(t), tagNoun(want) },
                        "Run this file with the interpreter.",
                    );
                }
            };
            // Only `orelse` acts on `never`: it drops the left side.
            if (snd.under_orelse and snd.never and !self.sendNeverReturns(snd.message)) return self.reject(
                snd.loc,
                "This send of :{s} was compiled before its handler, as never handing back a value; the handler can.",
                .{snd.message},
                "Declare the handler before the code that sends to it, or run this file with the interpreter.",
            );
            if (any and now != snd.reply) return self.reject(
                snd.loc,
                "This send of :{s} was compiled before its handler, as replying {s}; the handler replies {s}.",
                .{ snd.message, tagNoun(snd.reply), tagNoun(now) },
                "Declare the handler before the code that sends to it, or run this file with the interpreter.",
            );
        }
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
            // Carry on in a fresh block with no predecessors.  The function's
            // last block is not that: it may be a raise path already ended.
            const dead_bb = c.LLVMAppendBasicBlockInContext(self.context, func, "after_branches");
            c.LLVMPositionBuilderAtEnd(self.builder, dead_bb);
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

    /// `x orelse y`: y when x bubbles (from anywhere inside x, as in the
    /// interpreter) or is nil.  A fault inside x is not caught here: it goes
    /// on to an enclosing try or the top.
    fn compileOrelse(self: *Codegen, ore: ast.Node.OrElseExpr, loc: ast.Loc) CodegenError!TaggedVal {
        const func = self.current_fn orelse return CodegenError.LLVMError;
        const fallback_bb = c.LLVMAppendBasicBlockInContext(self.context, func, "fallback");
        const merge_bb = c.LLVMAppendBasicBlockInContext(self.context, func, "orelse_merge");

        self.catches.append(self.allocator, .{ .kind = .orelse_, .landing = fallback_bb, .slot = null, .loc = loc }) catch return CodegenError.LLVMError;
        self.last_send_status = null;
        self.last_send_never = false;
        self.send_under_orelse = ore.try_expr.kind == .message_send;
        const try_val = self.compileExpr(ore.try_expr.*) catch |err| {
            _ = self.catches.pop();
            return err;
        };
        _ = self.catches.pop();

        // Nil.  For a send, the status says whether there was a reply: a
        // reply of 0 is a value, not nil.  For anything else the tag does:
        // a nil is nil, a boxed value is asked at run time, and an Int, a
        // Bool, a String or an Atom is never nil.  Comparing the i64 with 0
        // was the old test, and `x = 0; x orelse 5` gave 5.
        const try_end = c.LLVMGetInsertBlock(self.builder);
        const try_live = c.LLVMGetBasicBlockTerminator(try_end) == null;
        var try_i64: c.LLVMValueRef = null;
        if (try_live) {
            const is_nil: ?c.LLVMValueRef = if (ore.try_expr.kind == .message_send and self.last_send_status != null)
                c.LLVMBuildICmp(self.builder, c.LLVMIntEQ, self.last_send_status.?, c.LLVMConstInt(self.i8_type, Status.nil, 0), "noreply")
            else switch (try_val.tag) {
                .nil => c.LLVMConstInt(self.i1_type, 1, 0),
                .tagged_val => blk: {
                    const f = self.getRuntimeFn("blimp_val_is_nil", &.{self.ptr_type}, self.i32_type);
                    var pt = [_]c.LLVMTypeRef{self.ptr_type};
                    var args = [_]c.LLVMValueRef{try_val.val};
                    const r = c.LLVMBuildCall2(self.builder, c.LLVMFunctionType(self.i32_type, &pt, 1, 0), f, &args, 1, "is_nil");
                    break :blk c.LLVMBuildICmp(self.builder, c.LLVMIntNE, r, c.LLVMConstInt(self.i32_type, 0, 0), "isniltmp");
                },
                else => null,
            };
            if (is_nil) |cond| {
                _ = c.LLVMBuildCondBr(self.builder, cond, fallback_bb, merge_bb);
            } else {
                _ = c.LLVMBuildBr(self.builder, merge_bb);
            }
        }

        // Fallback block
        c.LLVMPositionBuilderAtEnd(self.builder, fallback_bb);
        const fallback_val = try self.compileExpr(ore.fallback.*);
        const fallback_end = c.LLVMGetInsertBlock(self.builder);
        const fallback_live = c.LLVMGetBasicBlockTerminator(fallback_end) == null;

        // One tag on both sides: that tag.  A nil left side only ever takes
        // the fallback, so the fallback's.  Otherwise both are boxed, as
        // try's two arms are.  Each side is widened in its own block: the
        // widening used to be emitted in the merge block, which LLVM
        // refused for anything not already an i64.
        const left_never = ore.try_expr.kind == .message_send and self.last_send_never;
        const left_counts = try_live and try_val.tag != .nil and !left_never;
        const same = !left_counts or !fallback_live or try_val.tag == fallback_val.tag;
        const result_tag: ValTag = if (!left_counts) fallback_val.tag else if (same) try_val.tag else .tagged_val;
        var fallback_i64: c.LLVMValueRef = null;
        if (fallback_live) {
            fallback_i64 = if (same) self.coerceToI64(fallback_val) else self.coerceToI64(.{ .val = self.wrapAsBlimpVal(fallback_val), .tag = .tagged_val });
            _ = c.LLVMBuildBr(self.builder, merge_bb);
        }
        const fallback_from = c.LLVMGetInsertBlock(self.builder);
        if (try_live) {
            // Before the branch try_end ended with.
            c.LLVMPositionBuilderBefore(self.builder, c.LLVMGetBasicBlockTerminator(try_end));
            try_i64 = if (!left_counts)
                c.LLVMConstInt(self.i64_type, 0, 0)
            else if (same)
                self.coerceToI64(try_val)
            else
                self.coerceToI64(.{ .val = self.wrapAsBlimpVal(try_val), .tag = .tagged_val });
        }

        c.LLVMPositionBuilderAtEnd(self.builder, merge_bb);
        var vals: [2]c.LLVMValueRef = undefined;
        var blocks: [2]c.LLVMBasicBlockRef = undefined;
        var n: u32 = 0;
        if (try_live) {
            vals[n] = try_i64;
            blocks[n] = try_end;
            n += 1;
        }
        if (fallback_live) {
            vals[n] = fallback_i64;
            blocks[n] = fallback_from;
            n += 1;
        }
        if (n == 0) return .{ .val = c.LLVMConstInt(self.i64_type, 0, 0), .tag = .nil };
        const phi = c.LLVMBuildPhi(self.builder, self.i64_type, "orelse");
        c.LLVMAddIncoming(phi, &vals, &blocks, n);
        return .{ .val = self.coerceFromI64(phi, result_tag), .tag = result_tag };
    }

    /// `try do ... catch e do ... end`.  Any bubble or fault raised in the
    /// body (in this function, or returned by a send) lands in the catch
    /// block with its BlimpRaise*; `e` is the bubble's reason, or the atom
    /// the interpreter binds (:division_by_zero, :undefined, :bubble).
    fn compileTryCatch(self: *Codegen, tc: ast.Node.TryCatch, loc: ast.Loc) CodegenError!TaggedVal {
        const func = self.current_fn orelse return CodegenError.LLVMError;
        const slot = c.LLVMBuildAlloca(self.builder, self.ptr_type, "raised");
        const catch_bb = c.LLVMAppendBasicBlockInContext(self.context, func, "catch");
        const merge_bb = c.LLVMAppendBasicBlockInContext(self.context, func, "try_merge");

        self.catches.append(self.allocator, .{ .kind = .try_, .landing = catch_bb, .slot = slot, .loc = loc }) catch return CodegenError.LLVMError;
        var body_val: TaggedVal = .{ .val = c.LLVMConstInt(self.i64_type, 0, 0), .tag = .nil };
        for (tc.try_body) |stmt| {
            body_val = self.compileExpr(stmt) catch |err| {
                _ = self.catches.pop();
                return err;
            };
        }
        _ = self.catches.pop();
        const body_end = c.LLVMGetInsertBlock(self.builder);

        // The catch body runs outside this try: a raise in it goes further out.
        c.LLVMPositionBuilderAtEnd(self.builder, catch_bb);
        if (tc.catch_var) |name| {
            const f = self.getRuntimeFn("blimp_raise_reason", &.{self.ptr_type}, self.ptr_type);
            var args = [_]c.LLVMValueRef{c.LLVMBuildLoad2(self.builder, self.ptr_type, slot, "raise")};
            var pt = [_]c.LLVMTypeRef{self.ptr_type};
            const reason = c.LLVMBuildCall2(self.builder, c.LLVMFunctionType(self.ptr_type, &pt, 1, 0), f, &args, 1, "reason");
            const alloca = c.LLVMBuildAlloca(self.builder, self.ptr_type, self.zname(name));
            _ = c.LLVMBuildStore(self.builder, reason, alloca);
            self.scope.put(self.allocator, .{ .name = name, .alloca = alloca, .tag = .tagged_val, .llvm_type = self.ptr_type });
        }
        var catch_val: TaggedVal = .{ .val = c.LLVMConstInt(self.i64_type, 0, 0), .tag = .nil };
        for (tc.catch_body) |stmt| {
            catch_val = try self.compileExpr(stmt);
        }
        const catch_end = c.LLVMGetInsertBlock(self.builder);

        // Both arms meet as one value.  Same tag: as i64.  Different tags
        // (an Int reply against a caught reason): both boxed as BlimpVal*.
        const same = body_val.tag == catch_val.tag;
        const result_tag: ValTag = if (same) body_val.tag else .tagged_val;
        var vals: [2]c.LLVMValueRef = undefined;
        var blocks: [2]c.LLVMBasicBlockRef = undefined;
        var n: u32 = 0;
        for ([_]struct { bb: c.LLVMBasicBlockRef, tv: TaggedVal }{
            .{ .bb = body_end, .tv = body_val },
            .{ .bb = catch_end, .tv = catch_val },
        }) |arm| {
            if (c.LLVMGetBasicBlockTerminator(arm.bb) != null) continue;
            c.LLVMPositionBuilderAtEnd(self.builder, arm.bb);
            vals[n] = if (same) self.coerceToI64(arm.tv) else self.coerceToI64(.{ .val = self.wrapAsBlimpVal(arm.tv), .tag = .tagged_val });
            blocks[n] = c.LLVMGetInsertBlock(self.builder);
            n += 1;
            _ = c.LLVMBuildBr(self.builder, merge_bb);
        }
        c.LLVMPositionBuilderAtEnd(self.builder, merge_bb);
        if (n == 0) return .{ .val = c.LLVMConstInt(self.i64_type, 0, 0), .tag = .nil };
        const phi = c.LLVMBuildPhi(self.builder, self.i64_type, "try_result");
        c.LLVMAddIncoming(phi, &vals, &blocks, n);
        return .{ .val = self.coerceFromI64(phi, result_tag), .tag = result_tag };
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
        for (nodes) |node| if (node.kind == .actor_def) {
            self.actor_names.append(self.allocator, node.kind.actor_def.name) catch return CodegenError.LLVMError;
        };

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
        try self.checkSends();

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

        self.emitAtomTable();
    }

    /// `blimp_atom_names` / `blimp_atom_count`: every atom in intern order,
    /// so the runtime can print a bubble's reason as `:too_small` rather than
    /// `:3`.  Emitted last, when every atom has been interned.
    fn emitAtomTable(self: *Codegen) void {
        const n: u32 = @intCast(self.atoms.names.items.len);
        const ptrs = self.allocator.alloc(c.LLVMValueRef, n) catch return;
        for (self.atoms.names.items, 0..) |name, i| {
            const s = c.LLVMConstStringInContext(self.context, self.zname(name), @intCast(name.len), 0);
            const g = c.LLVMAddGlobal(self.module, c.LLVMTypeOf(s), "atom_name");
            c.LLVMSetInitializer(g, s);
            c.LLVMSetGlobalConstant(g, 1);
            c.LLVMSetLinkage(g, c.LLVMPrivateLinkage);
            ptrs[i] = g;
        }
        const arr_ty = c.LLVMArrayType2(self.ptr_type, n);
        const table = c.LLVMAddGlobal(self.module, arr_ty, "blimp_atom_names");
        c.LLVMSetInitializer(table, c.LLVMConstArray2(self.ptr_type, ptrs.ptr, n));
        c.LLVMSetGlobalConstant(table, 1);
        const count = c.LLVMAddGlobal(self.module, self.i32_type, "blimp_atom_count");
        c.LLVMSetInitializer(count, c.LLVMConstInt(self.i32_type, n, 0));
        c.LLVMSetGlobalConstant(count, 1);
    }

    /// The LLVM name of `def name`.  A def is not a C function: named
    /// `printf` or `malloc` under its own name, it was the symbol the runtime
    /// linked for printf or malloc, and `def printf(n: Int)` turned every
    /// print in the program into a call to it.  `def.` cannot begin a C
    /// identifier, so no def can take a libc or runtime symbol.
    fn defSymbol(self: *Codegen, name: []const u8) [*:0]const u8 {
        const s = std.fmt.allocPrintSentinel(self.allocator, "def.{s}", .{name}, 0) catch return "def.?";
        return s.ptr;
    }

    /// Declare `def name` with internal linkage: nothing outside the module
    /// calls a def, so its symbol is never exported to the linker either.
    fn addDefFunction(self: *Codegen, name: []const u8, fn_type: c.LLVMTypeRef) c.LLVMValueRef {
        const func = c.LLVMAddFunction(self.module, self.defSymbol(name), fn_type);
        c.LLVMSetLinkage(func, c.LLVMInternalLinkage);
        return func;
    }

    /// Forward-declare all `def` functions so call order doesn't matter.
    fn forwardDeclareDefs(self: *Codegen, nodes: []const ast.Node) void {
        for (nodes) |node| {
            if (node.kind == .def_stmt) {
                const ds = node.kind.def_stmt;
                self.defs.append(self.allocator, ds) catch {};
                // Only declare if not already present
                if (c.LLVMGetNamedFunction(self.module, self.defSymbol(ds.name)) == null) {
                    const param_count: u32 = @intCast(ds.params.len);
                    const param_types = self.allocator.alloc(c.LLVMTypeRef, param_count) catch continue;
                    for (0..param_count) |i| {
                        param_types[i] = self.i64_type;
                    }
                    const fn_type = c.LLVMFunctionType(self.i64_type, param_types.ptr, param_count, 0);
                    _ = self.addDefFunction(ds.name, fn_type);
                }
            }
        }
    }

    /// Backward-compat: build main from a single expression.
    pub fn buildMainFunction(self: *Codegen, expr: ast.Node) CodegenError!void {
        return self.buildProgram(&.{expr});
    }

    /// An atom is an i32 id, except where it was widened to i64 to be
    /// stored (a state field, a handler's return value, a def's own name).
    fn atomId32(self: *Codegen, v: c.LLVMValueRef) c.LLVMValueRef {
        if (c.LLVMTypeOf(v) == self.i32_type) return v;
        return c.LLVMBuildTrunc(self.builder, v, self.i32_type, "atom_id");
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
                // By id, through the runtime's copy of the intern table: an
                // atom read from a variable or a state field is not a
                // constant, and printing only constants gave `:?` for those.
                const f = self.getRuntimeFn("blimp_print_atom_id", &.{self.i32_type}, self.void_type);
                var params = [_]c.LLVMTypeRef{self.i32_type};
                const ft = c.LLVMFunctionType(self.void_type, &params, 1, 0);
                var args = [_]c.LLVMValueRef{self.atomId32(tv.val)};
                _ = c.LLVMBuildCall2(self.builder, ft, f, &args, 1, "");
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
