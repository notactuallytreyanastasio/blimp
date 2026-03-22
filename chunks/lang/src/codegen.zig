const std = @import("std");
const ast = @import("ast.zig");

const c = @cImport({
    @cInclude("llvm-c/Core.h");
    @cInclude("llvm-c/Target.h");
    @cInclude("llvm-c/TargetMachine.h");
    @cInclude("llvm-c/Analysis.h");
});

pub const CodegenError = error{
    UnsupportedNode,
    LLVMError,
    VerificationFailed,
    TargetError,
    EmitError,
};

pub const Codegen = struct {
    context: c.LLVMContextRef,
    module: c.LLVMModuleRef,
    builder: c.LLVMBuilderRef,

    pub fn init(module_name: [*:0]const u8) Codegen {
        const ctx = c.LLVMContextCreate();
        const mod = c.LLVMModuleCreateWithNameInContext(module_name, ctx);
        const builder = c.LLVMCreateBuilderInContext(ctx);
        return .{
            .context = ctx,
            .module = mod,
            .builder = builder,
        };
    }

    pub fn deinit(self: *Codegen) void {
        c.LLVMDisposeBuilder(self.builder);
        c.LLVMDisposeModule(self.module);
        c.LLVMContextDispose(self.context);
    }

    /// Compile an expression AST node to an LLVM value (i64).
    pub fn compileExpression(self: *Codegen, node: ast.Node) CodegenError!c.LLVMValueRef {
        return switch (node.kind) {
            .integer_lit => |lit| self.compileIntegerLit(lit),
            .float_lit => |lit| self.compileFloatLit(lit),
            .bool_lit => |lit| self.compileBoolLit(lit),
            .binary_op => |op| self.compileBinaryOp(op),
            .unary_op => |op| self.compileUnaryOp(op),
            else => CodegenError.UnsupportedNode,
        };
    }

    fn compileIntegerLit(self: *Codegen, lit: ast.Node.IntegerLit) c.LLVMValueRef {
        const int_type = c.LLVMInt64TypeInContext(self.context);
        return c.LLVMConstInt(int_type, @bitCast(lit.value), 1);
    }

    fn compileFloatLit(self: *Codegen, lit: ast.Node.FloatLit) c.LLVMValueRef {
        const double_type = c.LLVMDoubleTypeInContext(self.context);
        return c.LLVMConstReal(double_type, lit.value);
    }

    fn compileBoolLit(self: *Codegen, lit: ast.Node.BoolLit) c.LLVMValueRef {
        const int_type = c.LLVMInt64TypeInContext(self.context);
        const val: u64 = if (lit.value) 1 else 0;
        return c.LLVMConstInt(int_type, val, 0);
    }

    fn compileBinaryOp(self: *Codegen, op: ast.Node.BinaryOp) CodegenError!c.LLVMValueRef {
        const lhs = try self.compileExpression(op.left.*);
        const rhs = try self.compileExpression(op.right.*);

        return switch (op.op) {
            .add => c.LLVMBuildAdd(self.builder, lhs, rhs, "addtmp"),
            .sub => c.LLVMBuildSub(self.builder, lhs, rhs, "subtmp"),
            .mul => c.LLVMBuildMul(self.builder, lhs, rhs, "multmp"),
            .div => c.LLVMBuildSDiv(self.builder, lhs, rhs, "divtmp"),
            .eq => blk: {
                const cmp = c.LLVMBuildICmp(self.builder, c.LLVMIntEQ, lhs, rhs, "eqtmp");
                break :blk c.LLVMBuildZExt(self.builder, cmp, c.LLVMInt64TypeInContext(self.context), "eqext");
            },
            .neq => blk: {
                const cmp = c.LLVMBuildICmp(self.builder, c.LLVMIntNE, lhs, rhs, "neqtmp");
                break :blk c.LLVMBuildZExt(self.builder, cmp, c.LLVMInt64TypeInContext(self.context), "neqext");
            },
            .lt => blk: {
                const cmp = c.LLVMBuildICmp(self.builder, c.LLVMIntSLT, lhs, rhs, "lttmp");
                break :blk c.LLVMBuildZExt(self.builder, cmp, c.LLVMInt64TypeInContext(self.context), "ltext");
            },
            .gt => blk: {
                const cmp = c.LLVMBuildICmp(self.builder, c.LLVMIntSGT, lhs, rhs, "gttmp");
                break :blk c.LLVMBuildZExt(self.builder, cmp, c.LLVMInt64TypeInContext(self.context), "gtext");
            },
            .lte => blk: {
                const cmp = c.LLVMBuildICmp(self.builder, c.LLVMIntSLE, lhs, rhs, "letmp");
                break :blk c.LLVMBuildZExt(self.builder, cmp, c.LLVMInt64TypeInContext(self.context), "leext");
            },
            .gte => blk: {
                const cmp = c.LLVMBuildICmp(self.builder, c.LLVMIntSGE, lhs, rhs, "getmp");
                break :blk c.LLVMBuildZExt(self.builder, cmp, c.LLVMInt64TypeInContext(self.context), "geext");
            },
            .and_op => c.LLVMBuildAnd(self.builder, lhs, rhs, "andtmp"),
            .or_op => c.LLVMBuildOr(self.builder, lhs, rhs, "ortmp"),
        };
    }

    fn compileUnaryOp(self: *Codegen, op: ast.Node.UnaryOp) CodegenError!c.LLVMValueRef {
        const operand = try self.compileExpression(op.operand.*);
        return switch (op.op) {
            .negate => c.LLVMBuildNeg(self.builder, operand, "negtmp"),
            .not => blk: {
                const zero = c.LLVMConstInt(c.LLVMInt64TypeInContext(self.context), 0, 0);
                const cmp = c.LLVMBuildICmp(self.builder, c.LLVMIntEQ, operand, zero, "nottmp");
                break :blk c.LLVMBuildZExt(self.builder, cmp, c.LLVMInt64TypeInContext(self.context), "notext");
            },
        };
    }

    /// Build a complete program: a main() that evaluates the expression,
    /// calls blimp_print_int with the result, and returns 0.
    pub fn buildMainFunction(self: *Codegen, expr: ast.Node) CodegenError!void {
        const int_type = c.LLVMInt64TypeInContext(self.context);
        const int32_type = c.LLVMInt32TypeInContext(self.context);

        // Declare: void blimp_print_int(i64)
        const void_type = c.LLVMVoidTypeInContext(self.context);
        var print_param_types = [_]c.LLVMTypeRef{int_type};
        const print_func_type = c.LLVMFunctionType(void_type, &print_param_types, 1, 0);
        const print_func = c.LLVMAddFunction(self.module, "blimp_print_int", print_func_type);

        // Define: i32 main()
        var main_param_types = [_]c.LLVMTypeRef{};
        const main_func_type = c.LLVMFunctionType(int32_type, &main_param_types, 0, 0);
        const main_func = c.LLVMAddFunction(self.module, "main", main_func_type);

        // Create entry block
        const entry = c.LLVMAppendBasicBlockInContext(self.context, main_func, "entry");
        c.LLVMPositionBuilderAtEnd(self.builder, entry);

        // Compile the expression
        const result = try self.compileExpression(expr);

        // Call blimp_print_int(result)
        var call_args = [_]c.LLVMValueRef{result};
        _ = c.LLVMBuildCall2(self.builder, print_func_type, print_func, &call_args, 1, "");

        // Return 0
        _ = c.LLVMBuildRet(self.builder, c.LLVMConstInt(int32_type, 0, 0));
    }

    /// Verify the module IR is well-formed.
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

    /// Dump the module IR to stderr (for debugging).
    pub fn dumpIR(self: *Codegen) void {
        c.LLVMDumpModule(self.module);
    }

    /// Emit an object file from the module.
    pub fn emitObjectFile(self: *Codegen, output_path: [*:0]const u8) CodegenError!void {
        // Initialize native target
        _ = c.LLVMInitializeNativeTarget();
        _ = c.LLVMInitializeNativeAsmPrinter();
        _ = c.LLVMInitializeNativeAsmParser();

        // Get the target triple
        const triple = c.LLVMGetDefaultTargetTriple();
        defer c.LLVMDisposeMessage(triple);

        // Look up the target
        var target: c.LLVMTargetRef = null;
        var err_msg: [*c]u8 = null;
        if (c.LLVMGetTargetFromTriple(triple, &target, &err_msg) != 0) {
            if (err_msg) |msg| {
                std.debug.print("LLVM target error: {s}\n", .{msg});
                c.LLVMDisposeMessage(msg);
            }
            return CodegenError.TargetError;
        }

        // Create target machine
        const machine = c.LLVMCreateTargetMachine(
            target,
            triple,
            "generic",
            "",
            c.LLVMCodeGenLevelDefault,
            c.LLVMRelocDefault,
            c.LLVMCodeModelDefault,
        );
        defer c.LLVMDisposeTargetMachine(machine);

        // Set the module target triple and data layout
        c.LLVMSetTarget(self.module, triple);
        const data_layout = c.LLVMCreateTargetDataLayout(machine);
        c.LLVMSetModuleDataLayout(self.module, data_layout);
        c.LLVMDisposeTargetData(data_layout);

        // Emit object file
        var emit_err: [*c]u8 = null;
        if (c.LLVMTargetMachineEmitToFile(machine, self.module, output_path, c.LLVMObjectFile, &emit_err) != 0) {
            if (emit_err) |msg| {
                std.debug.print("LLVM emit error: {s}\n", .{msg});
                c.LLVMDisposeMessage(msg);
            }
            return CodegenError.EmitError;
        }
    }
};
