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
}
