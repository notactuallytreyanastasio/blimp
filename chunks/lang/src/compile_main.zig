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
        std.debug.print("Usage: blimp-compile <file.blimp> [-o <output>] [--dump-ir] [--run]\n", .{});
        std.process.exit(1);
    }

    // Parse arguments
    const input_file = args[1];
    var output_name: []const u8 = "a.out";
    var dump_ir = false;
    var run_after = false;
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-o") and i + 1 < args.len) {
            output_name = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--dump-ir")) {
            dump_ir = true;
        } else if (std.mem.eql(u8, args[i], "--run")) {
            run_after = true;
        }
    }

    // Read source file
    const source = std.fs.cwd().readFileAlloc(allocator, input_file, 1024 * 1024) catch |err| {
        std.debug.print("Error reading '{s}': {}\n", .{ input_file, err });
        std.process.exit(1);
    };
    defer allocator.free(source);

    // Parse the source
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const program_nodes = parseProgram(arena.allocator(), source);

    // Codegen
    var codegen = Codegen.init(arena.allocator(), "blimp_module");
    defer codegen.deinit();

    codegen.buildProgram(program_nodes) catch |err| {
        std.debug.print("Codegen error: {}\n", .{err});
        std.process.exit(1);
    };

    if (dump_ir) {
        codegen.dumpIR();
    }

    codegen.verify() catch |err| {
        std.debug.print("Verification error: {}\n", .{err});
        codegen.dumpIR();
        std.process.exit(1);
    };

    // Emit object file
    const obj_path = try std.fmt.allocPrintSentinel(allocator, "{s}.o", .{output_name}, 0);
    defer allocator.free(obj_path);

    codegen.emitObjectFile(obj_path.ptr) catch |err| {
        std.debug.print("Emit error: {}\n", .{err});
        std.process.exit(1);
    };

    // Find the runtime object
    const self_exe_dir = try std.fs.selfExeDirPathAlloc(allocator);
    defer allocator.free(self_exe_dir);

    const runtime_obj_path = try std.fmt.allocPrint(allocator, "{s}/../lib/blimp_runtime.o", .{self_exe_dir});
    defer allocator.free(runtime_obj_path);

    // Link
    const link_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "cc", obj_path, runtime_obj_path, "-o", output_name },
    }) catch |err| {
        std.debug.print("Linker error: {}\n", .{err});
        std.process.exit(1);
    };
    defer allocator.free(link_result.stdout);
    defer allocator.free(link_result.stderr);

    switch (link_result.term) {
        .Exited => |code| {
            if (code != 0) {
                std.debug.print("Linker failed (exit {d}):\n{s}\n", .{ code, link_result.stderr });
                std.process.exit(1);
            }
        },
        else => {
            std.debug.print("Linker terminated abnormally:\n{s}\n", .{link_result.stderr});
            std.process.exit(1);
        },
    }

    // Clean up object file
    std.fs.cwd().deleteFile(obj_path) catch {};

    if (run_after) {
        // Execute the compiled binary (use absolute path)
        const abs_output = try std.fs.cwd().realpathAlloc(allocator, output_name);
        defer allocator.free(abs_output);
        const abs_z = try allocator.dupeZ(u8, abs_output);
        defer allocator.free(abs_z);

        const run_result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{abs_z},
        }) catch |err| {
            std.debug.print("Run error: {}\n", .{err});
            std.process.exit(1);
        };
        defer allocator.free(run_result.stdout);
        defer allocator.free(run_result.stderr);

        // Print stdout/stderr
        if (run_result.stdout.len > 0) {
            const stdout = std.fs.File.stdout();
            stdout.writeAll(run_result.stdout) catch {};
        }
        if (run_result.stderr.len > 0) {
            const stderr = std.fs.File.stderr();
            stderr.writeAll(run_result.stderr) catch {};
        }

        // Clean up binary
        std.fs.cwd().deleteFile(output_name) catch {};
    } else {
        std.debug.print("Compiled: {s} -> {s}\n", .{ input_file, output_name });
    }
}

fn parseProgram(arena: std.mem.Allocator, source: []const u8) []const ast.Node {
    var parser = Parser.init(arena, source);
    if (parser.parseFilePublic()) |nodes| {
        return nodes;
    } else |_| {}

    var parser2 = Parser.init(arena, source);
    const expr = parser2.parseExpressionPublic() catch |err| {
        std.debug.print("Parse error: {} at line {}, col {}\n", .{ err, parser2.current.line, parser2.current.col });
        std.process.exit(1);
    };
    const single = arena.alloc(ast.Node, 1) catch {
        std.debug.print("Out of memory\n", .{});
        std.process.exit(1);
    };
    single[0] = expr;
    return single;
}
