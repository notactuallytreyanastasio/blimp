const std = @import("std");
const Parser = @import("parser.zig").Parser;
const ast = @import("ast.zig");
const Codegen = @import("codegen.zig").Codegen;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: blimp-compile <file.blimp> [-o <output>]\n", .{});
        std.process.exit(1);
    }

    // Parse arguments
    const input_file = args[1];
    var output_name: []const u8 = "a.out";
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-o") and i + 1 < args.len) {
            output_name = args[i + 1];
            i += 1;
        }
    }

    // Read source file
    const source = std.fs.cwd().readFileAlloc(allocator, input_file, 1024 * 1024) catch |err| {
        std.debug.print("Error reading '{s}': {}\n", .{ input_file, err });
        std.process.exit(1);
    };
    defer allocator.free(source);

    // Parse the source as expression(s)
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var parser = Parser.init(arena.allocator(), source);
    const expr = parser.parseExpressionPublic() catch |err| {
        std.debug.print("Parse error: {} at line {}, col {}\n", .{ err, parser.current.line, parser.current.col });
        std.process.exit(1);
    };

    // Codegen
    var codegen = Codegen.init("blimp_module");
    defer codegen.deinit();

    codegen.buildMainFunction(expr) catch |err| {
        std.debug.print("Codegen error: {}\n", .{err});
        std.process.exit(1);
    };

    codegen.verify() catch |err| {
        std.debug.print("Verification error: {}\n", .{err});
        codegen.dumpIR();
        std.process.exit(1);
    };

    // Emit object file to a temp path
    const obj_path = try std.fmt.allocPrintSentinel(allocator, "{s}.o", .{output_name}, 0);
    defer allocator.free(obj_path);

    codegen.emitObjectFile(obj_path.ptr) catch |err| {
        std.debug.print("Emit error: {}\n", .{err});
        std.process.exit(1);
    };

    // Find the runtime object file next to the executable
    const self_exe_dir = try std.fs.selfExeDirPathAlloc(allocator);
    defer allocator.free(self_exe_dir);

    const runtime_obj_path = try std.fmt.allocPrint(allocator, "{s}/../lib/blimp_runtime.o", .{self_exe_dir});
    defer allocator.free(runtime_obj_path);

    // Link with cc
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "cc", obj_path, runtime_obj_path, "-o", output_name },
    }) catch |err| {
        std.debug.print("Linker error: {}\n", .{err});
        std.process.exit(1);
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| {
            if (code != 0) {
                std.debug.print("Linker failed (exit {d}):\n{s}\n", .{ code, result.stderr });
                std.process.exit(1);
            }
        },
        else => {
            std.debug.print("Linker terminated abnormally:\n{s}\n", .{result.stderr});
            std.process.exit(1);
        },
    }

    // Clean up object file
    std.fs.cwd().deleteFile(obj_path) catch {};

    std.debug.print("Compiled: {s} -> {s}\n", .{ input_file, output_name });
}
