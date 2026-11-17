const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // ReleaseSafe, not Debug, which is what `standardOptimizeOption` defaults
    // to when nothing asks otherwise.
    //
    // Everything anyone had ever measured of this interpreter was a Debug
    // build, because `zig build` produces one and `zig-out/bin/blimp` is what
    // goes on the PATH. A frame of snake took 379ms to render in Debug and
    // 35ms here -- an order of magnitude, for a flag.
    //
    // ReleaseSafe rather than ReleaseFast: ReleaseFast is another 2.3x (15ms)
    // and buys it by removing the overflow and bounds checks. An interpreter
    // that silently computes the wrong Int is the failure mode this project
    // has a rule against, and 35ms against a 200ms game tick is already five
    // times the headroom needed. `-Doptimize=ReleaseFast` is still there for
    // anyone who has measured and wants it.
    //
    // Not `standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe })`:
    // that only takes effect when `--release` is passed, and it removes
    // `-Doptimize` from the interface entirely. Declaring the option and
    // choosing the fallback keeps `-Doptimize=Debug` for anyone stepping
    // through the evaluator.
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Prioritize performance, safety, or binary size",
    ) orelse .ReleaseSafe;

    // -- Library module (lexer, parser, AST) --
    const lib_mod = b.addModule("blimp", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .link_libc = true,
    });

    // SQLite is compiled from the vendored amalgamation, not linked from the
    // system: Apple's libsqlite3 segfaults across fork() (see
    // vendor/sqlite/README), and Linux no longer needs libsqlite3-dev.
    // It is attached to the library module only; the executable and the test
    // binaries reach it through their import of `blimp`. The WASM build has
    // its own root module below and never sees it: the builtins are stubs.
    //
    // Warnings are off for this one file (it is not ours). The flags are the
    // ones the builtins lean on: THREADSAFE=1 because actors run on threads,
    // DQS=0 so "x" is never silently a string literal, OMIT_LOAD_EXTENSION so
    // there is no dlopen, FTS5 for search.
    lib_mod.addIncludePath(b.path("vendor/sqlite"));
    lib_mod.addCSourceFile(.{
        .file = b.path("vendor/sqlite/sqlite3.c"),
        .flags = &.{
            "-w",
            "-DSQLITE_THREADSAFE=1",
            "-DSQLITE_OMIT_LOAD_EXTENSION",
            "-DSQLITE_DQS=0",
            "-DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1",
            "-DSQLITE_OMIT_DEPRECATED",
            "-DSQLITE_ENABLE_FTS5",
        },
    });

    // -- CLI executable --
    const exe = b.addExecutable(.{
        .name = "blimp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            // fork, waitpid, isatty and realpath come from `std.c`. macOS
            // links libc whether or not it is asked to; Linux does not, and
            // without this the build stops at the first `extern "c"`.
            .link_libc = true,
            .imports = &.{
                .{ .name = "blimp", .module = lib_mod },
            },
        }),
    });
    b.installArtifact(exe);
    // main.zig imports eval.zig by path, so builtins.zig and native_ext.zig
    // (which @cInclude sqlite3.h) compile in the exe's own module, not
    // lib_mod. On macOS the SDK's sqlite3.h hid the missing path; a
    // x86_64-linux-musl cross-build, which is what the site ships, failed
    // with "sqlite3.h not found".
    exe.root_module.addIncludePath(b.path("vendor/sqlite"));

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

    // `lib.zig` does not reach `main.zig`, so for as long as the test step
    // depended only on the library module, a `test` block written in main.zig
    // was never compiled -- coverage that reads as coverage and runs nothing.
    // The CLI dispatch and the REPL live there.
    const main_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "blimp", .module = lib_mod },
            },
        }),
    });
    main_tests.root_module.addIncludePath(b.path("vendor/sqlite"));
    const run_main_tests = b.addRunArtifact(main_tests);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_lib_tests.step);
    test_step.dependOn(&run_main_tests.step);

    // -- Interpreter only --
    // The default step also builds blimp-compile, which needs an LLVM with
    // libLLVM on the machine (see findLlvm below).  The benchmarks, the REPL
    // and the test suite do not, so they ask for this instead of failing on a
    // dependency they never use.
    const interp_step = b.step("interp", "Build just the interpreter (no LLVM needed)");
    interp_step.dependOn(&b.addInstallArtifact(exe, .{}).step);

    // -- Compiler executable (blimp-compile, links LLVM) --
    const compile_exe = b.addExecutable(.{
        .name = "blimp-compile",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/compile_main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    // codegen.zig uses only the LLVM C API. Which LLVM: see findLlvm. When
    // none is found, only this artifact fails, by name, when something asks
    // for it; `zig build interp` and `zig build test` never look.
    const llvm_flag = b.option([]const u8, "llvm", "LLVM install prefix for blimp-compile (default: the first of findLlvm's list that exists)");
    switch (findLlvm(b, llvm_flag)) {
        .found => |llvm| {
            compile_exe.root_module.addSystemIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{llvm.prefix}) });
            compile_exe.root_module.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/lib", .{llvm.prefix}) });
            const say = b.allocator.create(SayLlvm) catch @panic("OOM");
            say.* = .{
                .step = std.Build.Step.init(.{ .id = .custom, .name = "say which LLVM", .owner = b, .makeFn = SayLlvm.make }),
                .prefix = llvm.prefix,
                .how = llvm.how,
            };
            compile_exe.step.dependOn(&say.step);
        },
        .missing => |why| compile_exe.step.dependOn(&b.addFail(why).step),
    }
    compile_exe.root_module.linkSystemLibrary("LLVM", .{});
    compile_exe.root_module.link_libc = true;

    // Compile and install the C runtime as a static object
    // Use ReleaseSafe to avoid UBSan symbols that won't link with plain cc
    const runtime_obj = b.addObject(.{
        .name = "blimp_runtime",
        .root_module = b.createModule(.{
            .root_source_file = null,
            .target = target,
            .optimize = .ReleaseSafe,
        }),
    });
    runtime_obj.root_module.addCSourceFile(.{ .file = b.path("src/runtime.c") });
    runtime_obj.root_module.link_libc = true;
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

    // -- WASM build (browser REPL) --
    const wasm_step = b.step("wasm", "Build Blimp interpreter as WASM module");
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });
    const wasm = b.addExecutable(.{
        .name = "blimp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wasm_api.zig"),
            .target = wasm_target,
            .optimize = .ReleaseSmall,
        }),
    });
    wasm.rdynamic = true;
    wasm.entry = .disabled;

    const install_wasm = b.addInstallArtifact(wasm, .{
        .dest_dir = .{ .override = .{ .custom = "web" } },
    });
    wasm_step.dependOn(&install_wasm.step);

    // TUI REPL is now in chunks/repl_tui (Rust/Ratatui)
}

// Where blimp-compile's LLVM comes from, in this order:
//
//  1. -Dllvm=PREFIX. Always wins. A PREFIX with no libLLVM in PREFIX/lib is
//     a failure that names it, not a reason to look elsewhere: whoever typed
//     it meant that one.
//  2. The prefixes below, first that exists. They are versioned paths on
//     purpose. LLVM 22 is first because every .expected in test/compiled and
//     every entry in test/diff/known.json was recorded against it; LLVM 23
//     gives the same results today (all fixtures, the whole harness), but
//     preferring the newest would let an upgrade change what the harness
//     compares without anyone choosing it. The unversioned
//     /opt/homebrew/opt/llvm is left out for the same reason: it is whatever
//     brew last upgraded to.
//  3. `llvm-config --prefix` from PATH, of whatever version: the usual case
//     on a Linux distribution's own llvm package. It is last because it is
//     the one nobody picked for this repository.
//
// Built and run (fixtures and harness) on macOS: /opt/homebrew/opt/llvm@22
// (22.1.8) and /opt/homebrew/opt/llvm@23 (23.1.5). The /usr/local and
// /usr/lib/llvm-N entries are the same versions in Intel Homebrew's and
// apt.llvm.org's layouts and have not been built here. llvm@20 was this
// file's only default until now and is kept last so a machine that has only
// it still builds; it has not been built here since the zig 0.16 port.
const llvm_prefixes = [_][]const u8{
    "/opt/homebrew/opt/llvm@22",
    "/usr/local/opt/llvm@22",
    "/usr/lib/llvm-22",
    "/opt/homebrew/opt/llvm@23",
    "/usr/local/opt/llvm@23",
    "/usr/lib/llvm-23",
    "/opt/homebrew/opt/llvm@20",
};

const Llvm = union(enum) {
    found: struct { prefix: []const u8, how: []const u8 },
    /// The message the compiler's build fails with.
    missing: []const u8,
};

fn hasLibLlvm(b: *std.Build, prefix: []const u8) bool {
    const io = b.graph.io;
    for ([_][]const u8{ "libLLVM.dylib", "libLLVM.so" }) |name| {
        const path = b.pathJoin(&.{ prefix, "lib", name });
        if (!std.fs.path.isAbsolute(path)) continue;
        std.Io.Dir.accessAbsolute(io, path, .{}) catch continue;
        return true;
    }
    return false;
}

fn findLlvm(b: *std.Build, flag: ?[]const u8) Llvm {
    const fix = "Give an LLVM install prefix: zig build -Dllvm=PREFIX, or make check LLVM=PREFIX";
    if (flag) |prefix| {
        if (hasLibLlvm(b, prefix)) return .{ .found = .{ .prefix = prefix, .how = "-Dllvm" } };
        return .{ .missing = b.fmt("blimp-compile: -Dllvm={s} has no lib/libLLVM.dylib or lib/libLLVM.so (an absolute path is required). {s}", .{ prefix, fix }) };
    }
    for (llvm_prefixes) |prefix| {
        if (hasLibLlvm(b, prefix)) return .{ .found = .{ .prefix = prefix, .how = "first of build.zig's list that exists; -Dllvm overrides" } };
    }
    var code: u8 = undefined;
    if (b.runAllowFail(&.{ "llvm-config", "--prefix" }, &code, .ignore)) |out| {
        const prefix = std.mem.trim(u8, out, " \n\r\t");
        if (hasLibLlvm(b, prefix)) return .{ .found = .{ .prefix = prefix, .how = "llvm-config --prefix on PATH; -Dllvm overrides" } };
    } else |_| {}
    var looked: std.ArrayList(u8) = .empty;
    for (llvm_prefixes) |prefix| looked.print(b.allocator, "{s}, ", .{prefix}) catch @panic("OOM");
    return .{ .missing = b.fmt("blimp-compile: no LLVM found. Looked for lib/libLLVM in {s}and in `llvm-config --prefix` from PATH. {s}", .{ looked.items, fix }) };
}

/// Prints which LLVM blimp-compile is built against, every time it is built,
/// so no result has to be guessed back to a version.
const SayLlvm = struct {
    step: std.Build.Step,
    prefix: []const u8,
    how: []const u8,

    fn make(step: *std.Build.Step, options: std.Build.Step.MakeOptions) anyerror!void {
        _ = options;
        const self: *SayLlvm = @fieldParentPtr("step", step);
        std.debug.print("blimp-compile: LLVM at {s} ({s})\n", .{ self.prefix, self.how });
    }
};
