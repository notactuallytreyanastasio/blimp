const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // -- Library module (lexer, parser, AST) --
    const lib_mod = b.addModule("blimp", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
    });

    // -- CLI executable --
    const exe = b.addExecutable(.{
        .name = "blimp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "blimp", .module = lib_mod },
            },
        }),
    });
    b.installArtifact(exe);

    // -- Run step --
    const run_step = b.step("run", "Run the Blimp parser");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // -- Tests --
    const lib_tests = b.addTest(.{
        .root_module = lib_mod,
    });
    const run_lib_tests = b.addRunArtifact(lib_tests);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_lib_tests.step);

    // -- Compiler executable (blimp-compile, links LLVM) --
    const compile_exe = b.addExecutable(.{
        .name = "blimp-compile",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/compile_main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    compile_exe.root_module.addSystemIncludePath(.{ .cwd_relative = "/opt/homebrew/opt/llvm@20/include" });
    compile_exe.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/opt/llvm@20/lib" });
    compile_exe.linkSystemLibrary("LLVM");
    compile_exe.linkLibC();

    // Compile and install the C runtime as a static object
    const runtime_obj = b.addObject(.{
        .name = "blimp_runtime",
        .root_module = b.createModule(.{
            .root_source_file = null,
            .target = target,
            .optimize = optimize,
        }),
    });
    runtime_obj.addCSourceFile(.{ .file = b.path("src/runtime.c") });
    runtime_obj.linkLibC();
    b.installArtifact(compile_exe);

    // Install the runtime object file alongside the compiler
    const install_runtime = b.addInstallArtifact(runtime_obj, .{
        .dest_dir = .{ .override = .{ .custom = "lib" } },
    });
    compile_exe.step.dependOn(&install_runtime.step);

    // -- Compile run step --
    const compile_run_step = b.step("compile-run", "Run the Blimp compiler");
    const compile_run_cmd = b.addRunArtifact(compile_exe);
    compile_run_step.dependOn(&compile_run_cmd.step);
    compile_run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        compile_run_cmd.addArgs(args);
    }

    // -- TUI REPL executable (blimp-tui, links libvaxis) --
    const vaxis_dep = b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
    });

    const tui_exe = b.addExecutable(.{
        .name = "blimp-tui",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tui_main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "blimp", .module = lib_mod },
                .{ .name = "vaxis", .module = vaxis_dep.module("vaxis") },
            },
        }),
    });
    b.installArtifact(tui_exe);

    // -- TUI run step --
    const tui_run_step = b.step("tui", "Run the Blimp TUI REPL");
    const tui_run_cmd = b.addRunArtifact(tui_exe);
    tui_run_step.dependOn(&tui_run_cmd.step);
    tui_run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        tui_run_cmd.addArgs(args);
    }
}
