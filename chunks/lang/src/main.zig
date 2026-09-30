const std = @import("std");
const Lexer = @import("lexer.zig").Lexer;
const Parser = @import("parser.zig").Parser;
const ast = @import("ast.zig");
const Checker = @import("checker.zig").Checker;
const introspect = @import("introspect.zig");
const Evaluator = @import("eval.zig").Evaluator;
const Value = @import("value.zig").Value;
const errors = @import("errors.zig");
const gc = @import("gc.zig");
const HeapLimit = @import("heap_limit.zig").HeapLimit;
const ioenv = @import("ioenv.zig");

/// The evaluator recurses natively: one Blimp call costs about 16 KB of Zig
/// frames, and `Evaluator.default_max_call_depth` of them do not fit in the
/// 8 MB the main thread gets.  Everything therefore runs on a thread sized to
/// hold them three times over, so the depth ceiling is what stops a runaway
/// recursion — with a message and a source line — rather than SIGSEGV.  The
/// reservation is address space; only the frames a program really uses are
/// ever touched.
const eval_stack_bytes = 512 * 1024 * 1024;

/// The largest program file blimp reads. It was 1 MiB, and bobbby.online's
/// server program passed that once /blinks moved in (1.28 MB), so every run
/// stopped with "error.StreamTooLong" before parsing a line. Same as
/// read_file's ceiling in builtins.zig.
pub const source_file_max = 64 * 1024 * 1024;

/// zig 0.16 stopped letting a program help itself to argv: `main` is handed a
/// capability instead, and `std.process.argsAlloc` is gone.  The vector is
/// passed down to the worker thread because it is the thread that reads it.
pub fn main(init: std.process.Init.Minimal) !void {
    var thread = try std.Thread.spawn(
        .{ .stack_size = eval_stack_bytes },
        runOnBigStack,
        .{ init.args, init.environ },
    );
    thread.join();
}

/// Milliseconds since the epoch. zig 0.16 removed `std.time.milliTimestamp`.
fn nowMillis() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000_000);
}

fn runOnBigStack(args: std.process.Args, environ: std.process.Environ) void {
    run(args, environ) catch |err| {
        std.debug.print("Error: {}\n", .{err});
        std.process.exit(1);
    };
}

fn run(argv: std.process.Args, environ: std.process.Environ) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args_arena = std.heap.ArenaAllocator.init(allocator);
    defer args_arena.deinit();
    const args = try argv.toSlice(args_arena.allocator());

    // zig 0.16 made I/O a capability. `main` is the only place that can build
    // one, and a builtin is a `fn (Allocator, []const *const Value)`, so it is
    // parked where the builtins can reach it rather than threaded through
    // every one of them.
    var threaded: std.Io.Threaded = .init(allocator, .{
        .argv0 = .init(argv),
        .environ = environ,
    });
    defer threaded.deinit();
    ioenv.install(threaded.io());

    // Everything a Blimp program allocates comes through here.  Reading the
    // source, the argv and the ASTs do not: the ceiling is about the program's
    // appetite, not the tool's.
    var heap_limit = HeapLimit.fromEnv(allocator, environ);
    const program_heap = heap_limit.allocator();

    // Check for --repl flag
    if (args.len >= 2 and std.mem.eql(u8, args[1], "--repl")) {
        // `blimp --repl foo.blimp` evaluates the file first. Blimp has no
        // module system, so there is no `require` to type at the prompt: a
        // REPL over a generated library could otherwise only be reached by
        // pasting the whole file in.
        const preload = if (args.len >= 3) args[2] else null;
        // `std.posix.isatty` is gone and `Io.File.isTty` wants an Io, which
        // nothing else here needs, so this asks libc the same question.
        const is_tty = std.c.isatty(std.posix.STDOUT_FILENO) != 0;
        if (is_tty) {
            repl(allocator, &heap_limit, preload);
        } else {
            replPlain(allocator, &heap_limit, preload);
        }
        return;
    }

    // blimp --serve site.blimp --tick "server <- :tick" [--control PATH]
    // Run one program for as long as the process lives: boot the file once,
    // then evaluate the tick forever, collecting garbage between ticks and
    // taking code from a control socket. See `serve` below.
    if (args.len >= 2 and std.mem.eql(u8, args[1], "--serve")) {
        const opts = parseServeArgs(args) orelse {
            std.debug.print("usage: blimp --serve FILE --tick EXPR [--control PATH]\n", .{});
            std.process.exit(2);
        };
        serve(allocator, &heap_limit, opts);
        return;
    }

    // blimp --attach [PATH]: a prompt on a running --serve program.
    if (args.len >= 2 and std.mem.eql(u8, args[1], "--attach")) {
        attach(allocator, if (args.len >= 3) args[2] else default_control_path);
        return;
    }

    // blimp test [dir] -- discover and run *_test.blimp files
    if (args.len >= 2 and std.mem.eql(u8, args[1], "test")) {
        const test_dir = if (args.len >= 3) args[2] else "test";
        runTestDir(program_heap, test_dir);
        return;
    }

    if (args.len < 2) {
        // No arguments -- enter REPL mode
        const is_tty = std.c.isatty(std.posix.STDOUT_FILENO) != 0;
        if (is_tty) {
            repl(allocator, &heap_limit, null);
        } else {
            replPlain(allocator, &heap_limit, null);
        }
        return;
    }

    const source = std.Io.Dir.cwd().readFileAlloc(ioenv.io, args[1], allocator, .limited(source_file_max)) catch |err| {
        if (err == error.StreamTooLong) {
            std.debug.print("Error reading '{s}': larger than {d} bytes, the most blimp reads\n", .{ args[1], source_file_max });
        } else std.debug.print("Error reading '{s}': {}\n", .{ args[1], err });
        std.process.exit(1);
    };
    defer allocator.free(source);

    var arena = std.heap.ArenaAllocator.init(program_heap);
    defer arena.deinit();

    var parser = Parser.init(arena.allocator(), source);
    const nodes = parser.parseFile() catch |err| {
        std.debug.print("Parse error: {} at line {}, col {}\n", .{ err, parser.current.line, parser.current.col });
        std.process.exit(1);
    };

    // Type check — mandatory, no bypass
    var checker = Checker.init(arena.allocator());
    const check_result = checker.checkFile(nodes);
    if (check_result.errors.len > 0) {
        for (check_result.errors) |type_err| {
            std.debug.print("Type error at line {}, col {}: {s}\n", .{
                type_err.loc.line,
                type_err.loc.col,
                type_err.message,
            });
        }
        std.debug.print("{d} type error(s) found.\n", .{check_result.errors.len});
        std.process.exit(1);
    }

    // Check for --introspect flag
    if (args.len >= 3 and std.mem.eql(u8, args[2], "--introspect")) {
        var stdout_buf: [16384]u8 = undefined;
        var stdout_writer = std.Io.File.stdout().writer(ioenv.io, &stdout_buf);
        introspect.writeJson(&stdout_writer.interface, nodes, source, arena.allocator());
        stdout_writer.interface.writeAll("\n") catch {};
        stdout_writer.interface.flush() catch {};
        return;
    }

    // Check for --ast flag (print AST without evaluating)
    if (args.len >= 3 and std.mem.eql(u8, args[2], "--ast")) {
        var stdout_buf: [4096]u8 = undefined;
        var stdout_writer = std.Io.File.stdout().writer(ioenv.io, &stdout_buf);
        printNodes(&stdout_writer.interface, nodes, 0);
        stdout_writer.interface.flush() catch {};
        return;
    }

    // Check for --self-hosted flag: load Blimp compiler, then eval user code through it
    if (args.len >= 3 and std.mem.eql(u8, args[2], "--self-hosted")) {
        runSelfHosted(allocator, source, nodes, arena.allocator());
        return;
    }

    // Check for --test flag (run test blocks)
    if (args.len >= 3 and std.mem.eql(u8, args[2], "--test")) {
        var evaluator = Evaluator.init(arena.allocator());
        evaluator.setSource(source);
        const start = nowMillis();
        const all_passed = evaluator.runTests(nodes);
        const elapsed = nowMillis() - start;
        var tbuf: [64]u8 = undefined;
        const timing = std.fmt.bufPrint(&tbuf, "\nFinished in {d}ms\n", .{elapsed}) catch "\n";
        std.Io.File.stderr().writeStreamingAll(ioenv.io, timing) catch {};
        if (!all_passed) std.process.exit(1);
        return;
    }

    // Default: evaluate the file
    var evaluator = Evaluator.init(arena.allocator());
    evaluator.setSource(source);
    // Store the absolute path so the Hole operator can patch the source file
    // `realpathAlloc` is gone from the Dir API; libc's realpath still answers
    // the same question, and the Hole operator only needs something it can
    // reopen for writing.
    const abs_path = blk: {
        var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const c_path = arena.allocator().dupeZ(u8, args[1]) catch break :blk args[1];
        const resolved = std.c.realpath(c_path, &path_buf) orelse break :blk args[1];
        break :blk arena.allocator().dupe(u8, std.mem.span(resolved)) catch args[1];
    };
    evaluator.source_path = abs_path;
    // Build null-terminated argv for re-exec after Hole patching
    var restart_argv = try arena.allocator().alloc([:0]const u8, args.len);
    for (args, 0..) |a, i| restart_argv[i] = try arena.allocator().dupeZ(u8, a);
    evaluator.restart_argv = restart_argv;
    for (nodes) |node| {
        _ = evaluator.eval(node) catch |err| {
            if (heap_limit.hit) {
                heap_limit.report();
                std.process.exit(1);
            }
            if (err == error.Bubble and evaluator.last_error == null) {
                evaluator.last_error = errors.uncaughtBubble(
                    evaluator.bubble_reason,
                    source,
                    evaluator.bubble_line,
                    evaluator.bubble_col,
                );
            }
            if (evaluator.last_error) |blimp_err| {
                var buf: [2048]u8 = undefined;
                var fbs = std.Io.Writer.fixed(&buf);
                blimp_err.format(&fbs);
                std.debug.print("{s}\n", .{fbs.buffered()});
            } else {
                std.debug.print("Runtime error: {}\n", .{err});
            }
            std.process.exit(1);
        };
    }
}

fn printNodes(writer: *std.Io.Writer, nodes: []const ast.Node, indent: u32) void {
    for (nodes) |node| {
        printNode(writer, node, indent);
    }
}

fn printNode(writer: *std.Io.Writer, node: ast.Node, indent: u32) void {
    const pad = "                                        ";
    const prefix = pad[0..@min(indent * 2, pad.len)];

    switch (node.kind) {
        .actor_def => |a| {
            writer.print("{s}(actor {s}\n", .{ prefix, a.name }) catch {};
            printNodes(writer, a.body, indent + 1);
            writer.print("{s})\n", .{prefix}) catch {};
        },
        .state_def => |s| {
            writer.print("{s}(state", .{prefix}) catch {};
            for (s.fields) |f| {
                if (f.type_name) |tn| {
                    writer.print(" {s}: {s}", .{ f.key, tn }) catch {};
                    if (f.default_value != null) {
                        writer.print(" ::", .{}) catch {};
                        printInline(writer, f.value);
                    }
                } else {
                    writer.print(" {s}:", .{f.key}) catch {};
                    printInline(writer, f.value);
                }
            }
            writer.print(")\n", .{}) catch {};
        },
        .message_handler => |h| {
            writer.print("{s}(on :{s}", .{ prefix, h.name }) catch {};
            if (h.params.len > 0) {
                writer.print("(", .{}) catch {};
                for (h.params, 0..) |p, i| {
                    if (i > 0) writer.print(", ", .{}) catch {};
                    writer.print("{s}", .{p.name}) catch {};
                    if (p.type_name) |tn| {
                        writer.print(": {s}", .{tn}) catch {};
                    }
                }
                writer.print(")", .{}) catch {};
            }
            if (h.return_type) |rt| {
                writer.print(" -> {s}", .{rt}) catch {};
            }
            if (h.guard) |guard| {
                writer.print(" when", .{}) catch {};
                printInline(writer, guard.*);
            }
            if (h.bubble_strategy) |bs| {
                writer.print(" bubbles({s})", .{bs}) catch {};
            }
            writer.print("\n", .{}) catch {};
            printNodes(writer, h.body, indent + 1);
            writer.print("{s})\n", .{prefix}) catch {};
        },
        .become_stmt => |b| {
            writer.print("{s}(become", .{prefix}) catch {};
            for (b.fields) |f| {
                writer.print(" {s}:", .{f.key}) catch {};
                printInline(writer, f.value);
            }
            writer.print(")\n", .{}) catch {};
        },
        .reply_stmt => |r| {
            writer.print("{s}(reply", .{prefix}) catch {};
            printInline(writer, r.value.*);
            writer.print(")\n", .{}) catch {};
        },
        .assign_stmt => |a| {
            writer.print("{s}(= {s}", .{ prefix, a.name }) catch {};
            printInline(writer, a.value.*);
            writer.print(")\n", .{}) catch {};
        },
        .situation => |s| {
            writer.print("{s}(situation", .{prefix}) catch {};
            printInline(writer, s.subject.*);
            writer.print("\n", .{}) catch {};
            for (s.branches) |branch| {
                if (branch.pattern) |pat| {
                    writer.print("{s}  (branch", .{prefix}) catch {};
                    printInline(writer, pat.*);
                    writer.print("\n", .{}) catch {};
                } else {
                    writer.print("{s}  (branch _\n", .{prefix}) catch {};
                }
                printNodes(writer, branch.body, indent + 2);
                writer.print("{s}  )\n", .{prefix}) catch {};
            }
            writer.print("{s})\n", .{prefix}) catch {};
        },
        else => {
            writer.print("{s}", .{prefix}) catch {};
            printInline(writer, node);
            writer.print("\n", .{}) catch {};
        },
    }
}

fn printInline(writer: *std.Io.Writer, node: ast.Node) void {
    switch (node.kind) {
        .integer_lit => |i| writer.print(" {d}", .{i.value}) catch {},
        .float_lit => |f| writer.print(" {d}", .{f.value}) catch {},
        .string_lit => |s| writer.print(" {s}", .{s.value}) catch {},
        .atom_lit => |a| writer.print(" :{s}", .{a.name}) catch {},
        .bool_lit => |b| writer.print(" {}", .{b.value}) catch {},
        .nil_lit => writer.print(" nil", .{}) catch {},
        .identifier => |id| writer.print(" {s}", .{id.name}) catch {},
        .binary_op => |op| {
            writer.print(" ({s}", .{@tagName(op.op)}) catch {};
            printInline(writer, op.left.*);
            printInline(writer, op.right.*);
            writer.print(")", .{}) catch {};
        },
        .unary_op => |op| {
            writer.print(" ({s}", .{@tagName(op.op)}) catch {};
            printInline(writer, op.operand.*);
            writer.print(")", .{}) catch {};
        },
        .func_call => |c| {
            writer.print(" ({s}", .{c.name}) catch {};
            for (c.args) |arg| {
                printInline(writer, arg);
            }
            writer.print(")", .{}) catch {};
        },
        .pipe_expr => |p| {
            writer.print(" (|>", .{}) catch {};
            printInline(writer, p.left.*);
            printInline(writer, p.right.*);
            writer.print(")", .{}) catch {};
        },
        .list_lit => |l| {
            writer.print(" [", .{}) catch {};
            for (l.elements, 0..) |elem, i| {
                if (i > 0) writer.print(",", .{}) catch {};
                printInline(writer, elem);
            }
            if (l.tail) |t| {
                writer.print(" |", .{}) catch {};
                printInline(writer, t.*);
            }
            writer.print("]", .{}) catch {};
        },
        .tuple_lit => |t| {
            writer.print(" {{", .{}) catch {};
            for (t.elements, 0..) |elem, i| {
                if (i > 0) writer.print(",", .{}) catch {};
                printInline(writer, elem);
            }
            writer.print("}}", .{}) catch {};
        },
        .map_lit => |m| {
            writer.print(" %{{", .{}) catch {};
            for (m.entries, 0..) |e, i| {
                if (i > 0) writer.print(",", .{}) catch {};
                writer.print(" {s}:", .{e.key}) catch {};
                printInline(writer, e.value);
            }
            writer.print("}}", .{}) catch {};
        },
        .dot_access => |d| {
            printInline(writer, d.object.*);
            writer.print(".{s}", .{d.field}) catch {};
        },
        .hole => writer.print(" _", .{}) catch {},
        .situation => writer.print(" (situation ...)", .{}) catch {},
        .message_send => |ms| {
            writer.print(" (<-", .{}) catch {};
            printInline(writer, ms.target.*);
            writer.print(" :{s}", .{ms.message}) catch {};
            for (ms.args) |arg| {
                printInline(writer, arg);
            }
            writer.print(")", .{}) catch {};
        },
        .orelse_expr => |oe| {
            writer.print(" (orelse", .{}) catch {};
            printInline(writer, oe.try_expr.*);
            printInline(writer, oe.fallback.*);
            writer.print(")", .{}) catch {};
        },
        .spawn_expr => |se| {
            writer.print(" (spawn {s}", .{se.actor_name}) catch {};
            for (se.overrides) |ov| {
                writer.print(" {s}:", .{ov.key}) catch {};
                printInline(writer, ov.value);
            }
            writer.print(")", .{}) catch {};
        },
        else => writer.print(" ???", .{}) catch {},
    }
}

/// Count the net depth change from `do`/`end` keywords and brackets in a line.
fn countDepthChange(line: []const u8) i32 {
    var delta: i32 = 0;
    var i: usize = 0;
    while (i < line.len) {
        const c = line[i];
        // Brackets, parens, braces all contribute to depth
        if (c == '[' or c == '(' or c == '{') { delta += 1; i += 1; continue; }
        if (c == ']' or c == ')' or c == '}') { delta -= 1; i += 1; continue; }
        // Skip whitespace
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            i += 1;
            continue;
        }
        // Skip strings (don't count brackets inside strings)
        if (c == '"') {
            i += 1;
            while (i < line.len and line[i] != '"') {
                if (line[i] == '\\') i += 1; // skip escaped char
                i += 1;
            }
            if (i < line.len) i += 1; // skip closing "
            continue;
        }
        // Skip comments
        if (c == '#') break;
        // Check for "do" keyword at word boundary
        if (i + 2 <= line.len and std.mem.eql(u8, line[i .. i + 2], "do")) {
            const before_ok = (i == 0) or (!std.ascii.isAlphanumeric(line[i - 1]) and line[i - 1] != '_');
            const after_ok = (i + 2 >= line.len) or (!std.ascii.isAlphanumeric(line[i + 2]) and line[i + 2] != '_');
            if (before_ok and after_ok) {
                delta += 1;
                i += 2;
                continue;
            }
        }
        // Check for "catch" keyword (closes try block, net -1 with its do)
        if (i + 5 <= line.len and std.mem.eql(u8, line[i .. i + 5], "catch")) {
            const before_ok = (i == 0) or (!std.ascii.isAlphanumeric(line[i - 1]) and line[i - 1] != '_');
            const after_ok = (i + 5 >= line.len) or (!std.ascii.isAlphanumeric(line[i + 5]) and line[i + 5] != '_');
            if (before_ok and after_ok) {
                delta -= 1; // catch closes try block
                i += 5;
                continue;
            }
        }
        // Check for "end" keyword at word boundary
        if (i + 3 <= line.len and std.mem.eql(u8, line[i .. i + 3], "end")) {
            const before_ok = (i == 0) or (!std.ascii.isAlphanumeric(line[i - 1]) and line[i - 1] != '_');
            const after_ok = (i + 3 >= line.len) or (!std.ascii.isAlphanumeric(line[i + 3]) and line[i + 3] != '_');
            if (before_ok and after_ok) {
                delta -= 1;
                i += 3;
                continue;
            }
        }
        // Skip to next whitespace or bracket (move past current word)
        while (i < line.len and line[i] != ' ' and line[i] != '\t' and line[i] != '\n' and line[i] != '\r' and
            line[i] != '[' and line[i] != ']' and line[i] != '(' and line[i] != ')' and line[i] != '{' and line[i] != '}')
        {
            i += 1;
        }
    }
    return delta;
}

/// The evaluator's value heap, in two halves.
///
/// The evaluator allocates every value and frees nothing (see gc.zig), which
/// is fine for a one-shot run but not for a REPL: a session that evaluates
/// thousands of expressions against one evaluator grows without bound.
/// Between evals, `compact` copies what is still reachable into the idle half
/// and releases the busy one.
///
/// Source text and ASTs do not live here.  Closures and handlers keep pointing
/// at them and `compact` does not copy them, so they belong to an arena that
/// outlives every compaction.
const ValueHeap = struct {
    halves: [2]std.heap.ArenaAllocator,
    live: usize = 0,
    scratch: std.mem.Allocator,

    fn init(backing: std.mem.Allocator) ValueHeap {
        return .{
            .halves = .{
                std.heap.ArenaAllocator.init(backing),
                std.heap.ArenaAllocator.init(backing),
            },
            .scratch = backing,
        };
    }

    fn deinit(self: *ValueHeap) void {
        self.halves[0].deinit();
        self.halves[1].deinit();
    }

    fn allocator(self: *ValueHeap) std.mem.Allocator {
        return self.halves[self.live].allocator();
    }

    /// Only between evals: nothing on the Zig stack may hold a value pointer.
    /// A failed copy leaves the evaluator on the heap it already has, so the
    /// session keeps working and merely keeps the garbage.
    fn compact(self: *ValueHeap, eval: *Evaluator) void {
        const next = 1 - self.live;
        gc.compact(eval, self.halves[next].allocator(), self.scratch) catch return;
        _ = self.halves[self.live].reset(.free_all);
        self.live = next;
        // Its details have already been formatted for the user.
        eval.last_error = null;
    }
};

/// Evaluate a file into a REPL's environment before the first prompt.
///
/// This runs the same three steps `blimp foo.blimp` runs -- read, parse,
/// type-check, evaluate -- rather than the REPL's own read-eval, because a
/// file that `blimp foo.blimp` rejects must not be accepted just because the
/// prompt is going to follow it.
///
/// Anything that goes wrong exits instead of prompting. A `blimp>` that
/// appears after a half-evaluated file looks exactly like one where the load
/// worked, and the bindings that are missing are missing silently.
fn preloadInto(
    arena: std.mem.Allocator,
    evaluator: *Evaluator,
    writer: anytype,
    path: []const u8,
) void {
    // Same ceiling as a file run directly, so the two entry points accept the
    // same files.
    const source = std.Io.Dir.cwd().readFileAlloc(ioenv.io, path, arena, .limited(source_file_max)) catch |err| {
        if (err == error.StreamTooLong) {
            std.debug.print("Error reading '{s}': larger than {d} bytes, the most blimp reads\n", .{ path, source_file_max });
        } else std.debug.print("Error reading '{s}': {}\n", .{ path, err });
        std.process.exit(1);
    };
    preloadSource(arena, evaluator, writer, source) catch std.process.exit(1);
}

/// The part of a preload that has already read the file.
///
/// This is split out so it can be tested. The version that exits lives one
/// frame up: a helper that calls `std.process.exit` cannot be run by the test
/// runner, since it takes the test runner with it.
fn preloadSource(
    arena: std.mem.Allocator,
    evaluator: *Evaluator,
    writer: anytype,
    source: []const u8,
) error{PreloadFailed}!void {
    var parser = Parser.init(arena, source);
    const nodes = parser.parseFilePublic() catch {
        errors.parseError(source).formatPlain(writer);
        writer.flush() catch {};
        return error.PreloadFailed;
    };

    var checker = Checker.init(arena);
    const check_result = checker.checkFile(nodes);
    if (check_result.errors.len > 0) {
        for (check_result.errors) |type_err| {
            writer.print("Type error at line {}, col {}: {s}\n", .{
                type_err.loc.line,
                type_err.loc.col,
                type_err.message,
            }) catch {};
        }
        writer.print("{d} type error(s) found.\n", .{check_result.errors.len}) catch {};
        writer.flush() catch {};
        return error.PreloadFailed;
    }

    evaluator.setSource(source);
    for (nodes) |node| {
        _ = evaluator.eval(node) catch {
            if (evaluator.last_error) |rich_err| {
                rich_err.formatPlain(writer);
            } else {
                writer.writeAll("Error: unknown\n") catch {};
            }
            writer.flush() catch {};
            return error.PreloadFailed;
        };
    }
}

fn replPlain(allocator: std.mem.Allocator, heap_limit: *HeapLimit, preload: ?[]const u8) void {
    // Source text and the ASTs parsed from it outlive every compaction.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var heap = ValueHeap.init(heap_limit.allocator());
    defer heap.deinit();

    var evaluator = Evaluator.init(heap.allocator());
    evaluator.code_allocator = arena.allocator();
    var pending_garbage = false;

    var stdin_buf: [4096]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(ioenv.io, &stdin_buf);
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(ioenv.io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    if (preload) |path| {
        preloadInto(arena.allocator(), &evaluator, &stdout_writer.interface, path);
    }

    stdout.writeAll("Blimp REPL (type expressions, Ctrl-D to exit)\n") catch {};
    stdout_writer.interface.flush() catch {};

    var multi_buf = std.ArrayList(u8){ .items = &.{}, .capacity = 0 };
    var depth: i32 = 0;

    while (true) {
        // Between evals, and only here: no value pointer is on the stack.
        if (pending_garbage) {
            heap.compact(&evaluator);
            pending_garbage = false;
        }
        if (depth > 0) {
            stdout.writeAll("  ...  ") catch break;
        } else {
            stdout.writeAll("blimp> ") catch break;
        }
        stdout_writer.interface.flush() catch break;

        const line = stdin_reader.interface.takeDelimiterExclusive('\n') catch break;
        stdin_reader.interface.toss(1);
        if (line.len == 0 and depth == 0) continue;

        // Skip comment-only lines when not inside a block
        if (depth == 0) {
            var is_comment = false;
            for (line) |ch| {
                if (ch == ' ' or ch == '\t') continue;
                if (ch == '#') { is_comment = true; break; }
                break;
            }
            if (is_comment) continue;
        }

        // Accumulate into multi-line buffer
        if (multi_buf.items.len > 0) {
            multi_buf.append(arena.allocator(), '\n') catch continue;
        }
        multi_buf.appendSlice(arena.allocator(), line) catch continue;

        depth += countDepthChange(line);

        // If still inside a block, continue reading
        if (depth > 0) continue;

        // We have a complete input - copy it out and reset
        const source = arena.allocator().alloc(u8, multi_buf.items.len) catch continue;
        @memcpy(source, multi_buf.items);
        multi_buf.items.len = 0;
        depth = 0;

        pending_garbage = true;

        // Decide whether to use parseFile (multi-line with actor) or parseStatement
        const is_multiline = std.mem.indexOf(u8, source, "\n") != null;

        if (is_multiline) {
            var parser = Parser.init(arena.allocator(), source);
            const nodes = parser.parseFilePublic() catch {
                const parse_err = @import("errors.zig").parseError(source);
                parse_err.formatPlain(&stdout_writer.interface);
                stdout_writer.interface.flush() catch {};
                continue;
            };

            evaluator.setSource(source);
            var last_result: ?*const Value = null;
            var had_error = false;
            for (nodes) |node| {
                last_result = evaluator.eval(node) catch {
                    if (heap_limit.hit) {
                        heap_limit.report();
                        heap_limit.hit = false;
                    } else if (evaluator.last_error) |rich_err| {
                        rich_err.formatPlain(&stdout_writer.interface);
                    } else {
                        stdout.writeAll("Error: unknown\n") catch {};
                    }
                    stdout_writer.interface.flush() catch {};
                    had_error = true;
                    break;
                };
            }
            if (had_error) continue;

            if (last_result) |result| {
                stdout.writeAll("=> ") catch {};
                result.format(&stdout_writer.interface);
                stdout.writeAll("\n") catch {};
            }
        } else {
            var parser = Parser.init(arena.allocator(), source);
            const node = parser.parseStatementPublic() catch {
                const parse_err = @import("errors.zig").parseError(source);
                parse_err.formatPlain(&stdout_writer.interface);
                stdout_writer.interface.flush() catch {};
                continue;
            };

            evaluator.setSource(source);
            const result = evaluator.eval(node) catch {
                if (heap_limit.hit) {
                    heap_limit.report();
                    heap_limit.hit = false;
                } else if (evaluator.last_error) |rich_err| {
                    rich_err.formatPlain(&stdout_writer.interface);
                } else {
                    stdout.writeAll("Error: unknown\n") catch {};
                }
                stdout_writer.interface.flush() catch {};
                continue;
            };

            stdout.writeAll("=> ") catch {};
            result.format(&stdout_writer.interface);
            stdout.writeAll("\n") catch {};
        }

        // Print state in parseable format for LiveView
        const bindings = evaluator.env.allBindings(arena.allocator());
        const has_vars = bindings.len > 0;
        const has_actors = evaluator.registry.instances.items.len > 0;

        if (has_vars or has_actors) {
            stdout.writeAll("  ┌─ state ─────────────────────\n") catch {};

            // Print environment bindings
            for (bindings) |binding| {
                stdout.print("  │ {s} = ", .{binding.name}) catch {};
                binding.val.format(&stdout_writer.interface);
                stdout.writeAll("\n") catch {};
            }

            // Print actor instances
            for (evaluator.registry.instances.items) |instance| {
                stdout.print("  │ {s}#{d} = %{{", .{instance.ref.type_name, instance.ref.id}) catch {};
                for (instance.state_fields, 0..) |field, i| {
                    if (i > 0) stdout.writeAll(", ") catch {};
                    stdout.print("{s}: ", .{field.key}) catch {};
                    field.val.format(&stdout_writer.interface);
                }
                stdout.writeAll("}\n") catch {};
            }

            stdout.writeAll("  └─────────────────────────────\n") catch {};
        }
        stdout_writer.interface.flush() catch {};
    }
}

fn formatBlimpError(err: @import("errors.zig").BlimpError, alloc: std.mem.Allocator) []const u8 {
    var buf = std.ArrayList(u8){ .items = &.{}, .capacity = 0 };

    buf.appendSlice(alloc, "-- ") catch {};
    buf.appendSlice(alloc, err.title) catch {};
    buf.appendSlice(alloc, " --\n") catch {};
    buf.appendSlice(alloc, err.message) catch {};
    if (err.hint) |h| {
        buf.appendSlice(alloc, "\n") catch {};
        buf.appendSlice(alloc, h) catch {};
    }
    return buf.items;
}

const HistoryEntry = struct {
    kind: enum { input, output, err },
    text: []const u8,
};

/// Discover and run all *_test.blimp files in a directory.
/// Run user code through the self-hosted Blimp compiler.
/// The Zig evaluator loads the self-hosted compiler (lib/*.blimp),
/// then calls blimp_self_eval(user_source) to execute user code
/// through the Blimp-written pipeline.
fn runSelfHosted(gpa: std.mem.Allocator, user_source: []const u8, _: []const ast.Node, arena_alloc: std.mem.Allocator) void {
    const stderr = std.Io.File.stderr();
    var evaluator = Evaluator.init(arena_alloc);

    // Load self-hosted compiler components in order
    const lib_files = [_][]const u8{
        "lib/lexer.blimp",
        "lib/parser.blimp",
        "lib/eval.blimp",
        "lib/complete.blimp",
        "lib/codegen.blimp",
        "lib/compiler.blimp",
    };

    for (lib_files) |lib_path| {
        const lib_source = std.Io.Dir.cwd().readFileAlloc(ioenv.io, lib_path, gpa, .limited(source_file_max)) catch {
            stderr.writeStreamingAll(ioenv.io, "Failed to load: ") catch {};
            stderr.writeStreamingAll(ioenv.io, lib_path) catch {};
            stderr.writeStreamingAll(ioenv.io, "\n") catch {};
            std.process.exit(1);
        };
        var parser = Parser.init(arena_alloc, lib_source);
        const lib_nodes = parser.parseFile() catch {
            stderr.writeStreamingAll(ioenv.io, "Parse error in ") catch {};
            stderr.writeStreamingAll(ioenv.io, lib_path) catch {};
            stderr.writeStreamingAll(ioenv.io, "\n") catch {};
            std.process.exit(1);
        };
        for (lib_nodes) |node| {
            _ = evaluator.eval(node) catch {};
        }
    }

    stderr.writeStreamingAll(ioenv.io, "\x1b[33mself-hosted compiler loaded\x1b[0m\n") catch {};

    // Now call blimp_self_eval with the user's source code
    // We need to pass the source as a string value
    const source_val = arena_alloc.create(Value) catch return;
    source_val.* = Value{ .string = user_source };

    // Build AST: blimp_compile(source, :eval)
    const mode_val = arena_alloc.create(Value) catch return;
    mode_val.* = Value{ .atom = "eval" };

    // Call blimp_compile by evaluating it as a func_call
    const source_node = ast.Node{ .kind = .{ .string_lit = .{ .value = user_source } }, .loc = .{ .line = 0, .col = 0 } };
    const mode_node = ast.Node{ .kind = .{ .atom_lit = .{ .name = "eval" } }, .loc = .{ .line = 0, .col = 0 } };
    const call_node = ast.Node{
        .kind = .{ .func_call = .{ .name = "blimp_compile", .args = &.{ source_node, mode_node } } },
        .loc = .{ .line = 0, .col = 0 },
    };

    const result = evaluator.eval(call_node) catch |err| {
        if (evaluator.last_error) |blimp_err| {
            var buf: [2048]u8 = undefined;
            var fbs = std.Io.Writer.fixed(&buf);
            blimp_err.format(&fbs);
            stderr.writeStreamingAll(ioenv.io, fbs.buffered()) catch {};
            stderr.writeStreamingAll(ioenv.io, "\n") catch {};
        } else {
            stderr.writeStreamingAll(ioenv.io, "Self-hosted eval error: ") catch {};
            std.debug.print("{}\n", .{err});
        }
        std.process.exit(1);
    };

    // Print the result
    var buf: [4096]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    result.format(&fbs);
    const stdout = std.Io.File.stdout();
    stdout.writeStreamingAll(ioenv.io, fbs.buffered()) catch {};
    stdout.writeStreamingAll(ioenv.io, "\n") catch {};
}

fn runTestDir(gpa: std.mem.Allocator, dir_path: []const u8) void {
    var test_arena = std.heap.ArenaAllocator.init(gpa);
    defer test_arena.deinit();
    const allocator = test_arena.allocator();
    const stderr = std.Io.File.stderr();
    var dir = std.Io.Dir.cwd().openDir(ioenv.io, dir_path, .{ .iterate = true }) catch {
        stderr.writeStreamingAll(ioenv.io, "Could not open test directory: ") catch {};
        stderr.writeStreamingAll(ioenv.io, dir_path) catch {};
        stderr.writeStreamingAll(ioenv.io, "\n") catch {};
        std.process.exit(1);
    };
    defer dir.close(ioenv.io);

    var files: std.ArrayList([]const u8) = .empty;
    var iter = dir.iterate();
    while (iter.next(ioenv.io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.endsWith(u8, entry.name, "_test.blimp")) {
            const name = allocator.dupe(u8, entry.name) catch continue;
            files.append(allocator, name) catch continue;
        }
    }

    if (files.items.len == 0) {
        stderr.writeStreamingAll(ioenv.io, "No *_test.blimp files found in ") catch {};
        stderr.writeStreamingAll(ioenv.io, dir_path) catch {};
        stderr.writeStreamingAll(ioenv.io, "/\n") catch {};
        return;
    }

    // Sort for deterministic order
    std.mem.sort([]const u8, files.items, {}, struct {
        fn cmp(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.cmp);

    stderr.writeStreamingAll(ioenv.io, "\n") catch {};
    var any_failed = false;
    const start_time = nowMillis();

    for (files.items) |filename| {
        // Build full path
        const full_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, filename }) catch continue;

        stderr.writeStreamingAll(ioenv.io, "\x1b[1m") catch {};
        stderr.writeStreamingAll(ioenv.io, filename) catch {};
        stderr.writeStreamingAll(ioenv.io, "\x1b[0m\n") catch {};

        const source = std.Io.Dir.cwd().readFileAlloc(ioenv.io, full_path, allocator, .limited(source_file_max)) catch {
            stderr.writeStreamingAll(ioenv.io, "  \x1b[31mfailed to read file\x1b[0m\n") catch {};
            any_failed = true;
            continue;
        };

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        var parser = Parser.init(arena.allocator(), source);
        const nodes = parser.parseFile() catch {
            stderr.writeStreamingAll(ioenv.io, "  \x1b[31mparse error\x1b[0m\n") catch {};
            any_failed = true;
            continue;
        };

        var checker = Checker.init(arena.allocator());
        _ = checker.checkFile(nodes);

        var evaluator = Evaluator.init(arena.allocator());
        evaluator.setSource(source);
        if (!evaluator.runTests(nodes)) {
            any_failed = true;
        }
    }

    const elapsed = nowMillis() - start_time;
    var buf: [64]u8 = undefined;
    const timing = std.fmt.bufPrint(&buf, "\nFinished in {d}ms\n", .{elapsed}) catch "\n";
    stderr.writeStreamingAll(ioenv.io, timing) catch {};

    if (any_failed) std.process.exit(1);
}

fn repl(allocator: std.mem.Allocator, heap_limit: *HeapLimit, preload: ?[]const u8) void {
    // Source text, ASTs and the history lines outlive every compaction.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // Redrawing formats every binding and actor field again; that text is read
    // once and thrown away, so it gets an arena of its own.
    var draw_arena = std.heap.ArenaAllocator.init(allocator);
    defer draw_arena.deinit();

    var heap = ValueHeap.init(heap_limit.allocator());
    defer heap.deinit();

    var evaluator = Evaluator.init(heap.allocator());
    evaluator.code_allocator = arena.allocator();
    var pending_garbage = false;

    var stdin_buf: [4096]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(ioenv.io, &stdin_buf);
    var stdout_buf: [8192]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(ioenv.io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    var history = std.ArrayList(HistoryEntry){ .items = &.{}, .capacity = 0 };

    // Get terminal size
    const term_size = getTerminalSize();
    const total_cols = term_size.cols;
    const total_rows = term_size.rows;
    const left_cols = (total_cols * 3) / 4;
    const right_cols = total_cols - left_cols - 1; // -1 for border

    // Preload before the first draw, so the bindings a file brought in appear
    // in the environment pane rather than only after the first input.
    if (preload) |path| {
        preloadInto(arena.allocator(), &evaluator, &stdout_writer.interface, path);
    }

    // Initial draw
    drawScreen(stdout, &history, &evaluator, &draw_arena, total_rows, left_cols, right_cols);
    stdout_writer.interface.flush() catch {};

    var multi_buf = std.ArrayList(u8){ .items = &.{}, .capacity = 0 };
    var depth: i32 = 0;

    while (true) {
        // Between evals, and only here: no value pointer is on the stack.
        if (pending_garbage) {
            heap.compact(&evaluator);
            pending_garbage = false;
        }
        // Position cursor at input line
        moveCursor(stdout, total_rows, 1);
        // Clear the input line
        stdout.writeAll("\x1b[2K") catch {};
        if (depth > 0) {
            stdout.writeAll("\x1b[90m  ...\x1b[0m ") catch {};
        } else {
            stdout.writeAll("\x1b[32mblimp>\x1b[0m ") catch {};
        }
        stdout_writer.interface.flush() catch break;

        // Read a line from stdin
        const line = stdin_reader.interface.takeDelimiterExclusive('\n') catch break;
        stdin_reader.interface.toss(1);
        if (line.len == 0 and depth == 0) continue;

        // Copy line to arena
        const line_copy = arena.allocator().alloc(u8, line.len) catch continue;
        @memcpy(line_copy, line);

        // Accumulate into multi-line buffer
        if (multi_buf.items.len > 0) {
            multi_buf.append(arena.allocator(), '\n') catch continue;
        }
        multi_buf.appendSlice(arena.allocator(), line_copy) catch continue;

        depth += countDepthChange(line_copy);

        // If still inside a block, continue reading
        if (depth > 0) continue;

        // We have a complete input
        const source = arena.allocator().alloc(u8, multi_buf.items.len) catch continue;
        @memcpy(source, multi_buf.items);
        multi_buf.items.len = 0;
        depth = 0;

        // Record input
        history.append(arena.allocator(), .{ .kind = .input, .text = source }) catch {};

        pending_garbage = true;

        // Decide whether to use parseFile or parseStatement
        const is_multiline = std.mem.indexOf(u8, source, "\n") != null;

        if (is_multiline) {
            var parser = Parser.init(arena.allocator(), source);
            const nodes = parser.parseFilePublic() catch {
                const pe = @import("errors.zig").parseError(source);
                const err_text = formatBlimpError(pe, arena.allocator());
                history.append(arena.allocator(), .{ .kind = .err, .text = err_text }) catch {};
                drawScreen(stdout, &history, &evaluator, &draw_arena, total_rows, left_cols, right_cols);
                stdout_writer.interface.flush() catch {};
                continue;
            };

            evaluator.setSource(source);
            var last_result: ?*const Value = null;
            var had_error = false;
            for (nodes) |node| {
                last_result = evaluator.eval(node) catch {
                    const err_text = if (evaluator.last_error) |rich_err|
                        formatBlimpError(rich_err, arena.allocator())
                    else
                        "Unknown error";
                    history.append(arena.allocator(), .{ .kind = .err, .text = err_text }) catch {};
                    had_error = true;
                    break;
                };
            }
            if (had_error) {
                drawScreen(stdout, &history, &evaluator, &draw_arena, total_rows, left_cols, right_cols);
                stdout_writer.interface.flush() catch {};
                continue;
            }

            if (last_result) |result| {
                const result_text = formatValue(result, arena.allocator());
                history.append(arena.allocator(), .{ .kind = .output, .text = result_text }) catch {};
            }
        } else {
            var parser = Parser.init(arena.allocator(), source);
            const node = parser.parseStatementPublic() catch {
                const pe = @import("errors.zig").parseError(source);
                const err_text = formatBlimpError(pe, arena.allocator());
                history.append(arena.allocator(), .{ .kind = .err, .text = err_text }) catch {};
                drawScreen(stdout, &history, &evaluator, &draw_arena, total_rows, left_cols, right_cols);
                stdout_writer.interface.flush() catch {};
                continue;
            };

            evaluator.setSource(source);
            const result = evaluator.eval(node) catch {
                const err_text = if (evaluator.last_error) |rich_err|
                    formatBlimpError(rich_err, arena.allocator())
                else
                    "Unknown error";
                history.append(arena.allocator(), .{ .kind = .err, .text = err_text }) catch {};
                drawScreen(stdout, &history, &evaluator, &draw_arena, total_rows, left_cols, right_cols);
                stdout_writer.interface.flush() catch {};
                continue;
            };

            // Format result to string
            const result_text = formatValue(result, arena.allocator());
            history.append(arena.allocator(), .{ .kind = .output, .text = result_text }) catch {};
        }

        drawScreen(stdout, &history, &evaluator, &draw_arena, total_rows, left_cols, right_cols);
        stdout_writer.interface.flush() catch {};
    }

    // Restore terminal: move to bottom, clear
    moveCursor(stdout, total_rows, 1);
    stdout.writeAll("\n") catch {};
    stdout_writer.interface.flush() catch {};
}

fn formatValue(val: *const @import("value.zig").Value, alloc: std.mem.Allocator) []const u8 {
    var aw = std.Io.Writer.Allocating.init(alloc);
    val.format(&aw.writer);
    return aw.written();
}

fn getTerminalSize() struct { rows: u32, cols: u32 } {
    var ws: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    const err = std.posix.system.ioctl(std.posix.STDOUT_FILENO, std.posix.T.IOCGWINSZ, @intFromPtr(&ws));
    if (err == 0) {
        return .{ .rows = ws.row, .cols = ws.col };
    }
    return .{ .rows = 40, .cols = 120 };
}

fn moveCursor(writer: anytype, row: u32, col: u32) void {
    writer.print("\x1b[{d};{d}H", .{ row, col }) catch {};
}

fn drawScreen(
    writer: anytype,
    history: *const std.ArrayList(HistoryEntry),
    evaluator: *const Evaluator,
    scratch: *std.heap.ArenaAllocator,
    total_rows: u32,
    left_cols: u32,
    right_cols: u32,
) void {
    // Nothing formatted here outlives the draw.
    defer _ = scratch.reset(.retain_capacity);
    const alloc = scratch.allocator();
    const content_rows = total_rows - 1; // reserve bottom row for input

    // Clear screen
    writer.writeAll("\x1b[2J") catch {};

    // Draw the vertical border
    for (1..content_rows + 1) |row| {
        moveCursor(writer, @intCast(row), left_cols + 1);
        writer.writeAll("\x1b[90m│\x1b[0m") catch {};
    }

    // Draw state panel header (right side)
    moveCursor(writer, 1, left_cols + 3);
    writer.writeAll("\x1b[1;37m STATE \x1b[0m") catch {};

    // Draw state variables (right side)
    var current_row: u32 = 3;
    const bindings = evaluator.env.allBindings(alloc);

    // First, show environment bindings
    for (bindings) |binding| {
        if (current_row >= content_rows) break;
        moveCursor(writer, current_row, left_cols + 3);
        writer.print("\x1b[34m{s}\x1b[0m \x1b[90m=\x1b[0m ", .{binding.name}) catch {};

        // Format value, truncate to fit
        const val_text = formatValue(binding.val, alloc);
        const max_val_len = if (right_cols > 10) right_cols - 10 else 5;
        if (val_text.len > max_val_len) {
            writer.writeAll(val_text[0..max_val_len]) catch {};
            writer.writeAll("...") catch {};
        } else {
            writer.writeAll(val_text) catch {};
        }
        current_row += 1;
    }

    // Then, show actor instances
    for (evaluator.registry.instances.items) |instance| {
        if (current_row >= content_rows) break;
        moveCursor(writer, current_row, left_cols + 3);
        writer.print("\x1b[35m{s}#{d}\x1b[0m \x1b[90m=\x1b[0m %{{", .{instance.ref.type_name, instance.ref.id}) catch {};

        // Format state fields inline
        for (instance.state_fields, 0..) |field, i| {
            if (i > 0) writer.writeAll(", ") catch {};
            writer.print("{s}: ", .{field.key}) catch {};
            const val_text = formatValue(field.val, alloc);
            writer.writeAll(val_text) catch {};
        }
        writer.writeAll("}}") catch {};
        current_row += 1;
    }

    // Draw REPL history (left side), show last N entries that fit
    const max_history_lines = content_rows - 2; // leave room for header
    var lines_used: u32 = 0;

    // Count how many history entries fit (each entry is 1-2 lines)
    var start_idx: usize = 0;
    if (history.items.len > 0) {
        var count: u32 = 0;
        var idx: usize = history.items.len;
        while (idx > 0) {
            idx -= 1;
            const needed: u32 = if (history.items[idx].kind == .input) 2 else 1;
            if (count + needed > max_history_lines) {
                start_idx = idx + 1;
                break;
            }
            count += needed;
        }
    }

    // Header
    moveCursor(writer, 1, 2);
    writer.writeAll("\x1b[1;37m BLIMP REPL \x1b[90m(Ctrl-D to exit)\x1b[0m") catch {};
    lines_used = 2;

    // Render visible history
    for (history.items[start_idx..]) |entry| {
        lines_used += 1;
        if (lines_used >= content_rows) break;

        moveCursor(writer, lines_used, 2);

        switch (entry.kind) {
            .input => {
                writer.print("\x1b[32mblimp>\x1b[0m {s}", .{entry.text}) catch {};
            },
            .output => {
                writer.print("\x1b[37m=> {s}\x1b[0m", .{entry.text}) catch {};
            },
            .err => {
                writer.print("\x1b[31m{s}\x1b[0m", .{entry.text}) catch {};
            },
        }
    }
}

test "preloadSource puts a file's definitions in the environment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var evaluator = Evaluator.init(arena.allocator());
    var buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    try std.testing.expect(evaluator.env.lookup("double") == null);
    try preloadSource(
        arena.allocator(),
        &evaluator,
        &writer,
        "def double(n: Int) -> Int do\n  n * 2\nend\n",
    );
    try std.testing.expect(evaluator.env.lookup("double") != null);
}

test "preloadSource refuses a file that does not parse" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var evaluator = Evaluator.init(arena.allocator());
    var buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    try std.testing.expectError(
        error.PreloadFailed,
        preloadSource(arena.allocator(), &evaluator, &writer, "def f(n: Int) -> Int do\n  n\n"),
    );
}

test "preloadSource refuses a file whose top level fails" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var evaluator = Evaluator.init(arena.allocator());
    var buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    // The definition that came before the failure is in the environment, which
    // is exactly why the caller exits rather than prompting: a half-loaded
    // environment is indistinguishable from a loaded one at the prompt.
    try std.testing.expectError(
        error.PreloadFailed,
        preloadSource(
            arena.allocator(),
            &evaluator,
            &writer,
            "def f(n: Int) -> Int do\n  n\nend\nf(\"x\")\n",
        ),
    );
    try std.testing.expect(evaluator.env.lookup("f") != null);
}


// ── blimp --serve ────────────────────────────────────────────
//
// A program that serves a website has to live for as long as the site does,
// and the evaluator frees nothing on its own: a loop written in Blimp keeps
// every request's garbage (measured on the blog: 0.86MB a request). The REPL
// already knows the way out. Between two top-level evals nothing on the Zig
// stack points at a value, so the heap can be compacted then.
//
// So the loop lives here, in Zig. The file is evaluated once (boot); then
// `tick`, an expression such as `server <- :tick`, is evaluated at top level
// again and again, and the program does one bounded piece of work per tick
// (poll its sockets with a timeout, answer what is ready, return). Between
// ticks this loop:
//
//   - puts the environment and the actor context back to top level, so a
//     tick that failed half-way leaves nothing behind;
//   - empties the message log, which otherwise fills once and stays full;
//   - compacts when the heap has grown by as much as what survived the last
//     compaction (and at least 16MB), not after every tick: a compaction
//     costs time in proportion to what is live;
//   - answers the control socket, where each message is Blimp source,
//     evaluated at top level like a REPL line. That is how a person, or a
//     tool, redefines part of the site while it runs.
//
// The control socket is a Unix socket, 0600, so reaching it means being on
// the machine as that user. There is no other authentication.

const default_control_path = "blimp.sock";

const ServeOpts = struct {
    path: []const u8,
    tick: []const u8,
    control: []const u8,
};

fn parseServeArgs(args: []const [:0]const u8) ?ServeOpts {
    var opts = ServeOpts{ .path = "", .tick = "", .control = default_control_path };
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--tick") and i + 1 < args.len) {
            i += 1;
            opts.tick = args[i];
        } else if (std.mem.eql(u8, a, "--control") and i + 1 < args.len) {
            i += 1;
            opts.control = args[i];
        } else if (opts.path.len == 0) {
            opts.path = a;
        } else return null;
    }
    if (opts.path.len == 0 or opts.tick.len == 0) return null;
    return opts;
}

const ServeStats = struct {
    ticks: u64 = 0,
    errors: u64 = 0,
    compactions: u64 = 0,
    compact_ms: i64 = 0,
    live_after_compact: usize = 0,
    started_ms: i64 = 0,
};

fn serve(allocator: std.mem.Allocator, heap_limit: *HeapLimit, opts: ServeOpts) void {
    // Source text and ASTs: the file, the tick, and everything the control
    // socket is sent. They outlive every compaction.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var heap = ValueHeap.init(heap_limit.allocator());
    defer heap.deinit();

    var evaluator = Evaluator.init(heap.allocator());
    evaluator.code_allocator = arena.allocator();

    var err_buf: [4096]u8 = undefined;
    var err_writer = std.Io.File.stderr().writer(ioenv.io, &err_buf);
    const errw = &err_writer.interface;

    preloadInto(arena.allocator(), &evaluator, errw, opts.path);

    var tick_parser = Parser.init(arena.allocator(), opts.tick);
    const tick = tick_parser.parseStatementPublic() catch {
        std.debug.print("[serve] cannot parse the tick: {s}\n", .{opts.tick});
        std.process.exit(2);
    };

    // A browser that goes away while a page is being written turns the next
    // write into SIGPIPE, whose default is to end the process: the whole
    // site, for one closed tab. Ignored, the write returns an error instead,
    // which tcp_write reports as :error.
    const ignore = std.posix.Sigaction{ .handler = .{ .handler = std.posix.SIG.IGN }, .mask = std.posix.sigemptyset(), .flags = 0 };
    std.posix.sigaction(std.posix.SIG.PIPE, &ignore, null);

    var stats = ServeStats{ .started_ms = nowMillis() };
    serveResetToTop(&evaluator);
    heap.compact(&evaluator);
    stats.live_after_compact = heap_limit.used;
    std.debug.print("[serve] booted {s}; live heap {d} bytes; control socket {s}\n", .{ opts.path, heap_limit.used, opts.control });

    var control = Control.open(opts.control);
    defer control.close();

    while (true) {
        _ = evaluator.eval(tick) catch {
            stats.errors += 1;
            if (evaluator.last_error) |e| e.formatPlain(errw) else errw.print("[serve] tick failed\n", .{}) catch {};
            errw.flush() catch {};
            evaluator.last_error = null;
        };
        stats.ticks += 1;
        serveResetToTop(&evaluator);

        control.service(arena.allocator(), &evaluator, heap_limit, &stats);
        serveResetToTop(&evaluator);

        const grown = heap_limit.used -| stats.live_after_compact;
        if (grown >= @max(stats.live_after_compact, 16 * 1024 * 1024)) {
            const c0 = nowMillis();
            heap.compact(&evaluator);
            stats.compact_ms += nowMillis() - c0;
            stats.compactions += 1;
            stats.live_after_compact = heap_limit.used;
        }
    }
}

/// Back to the state a top-level eval starts from: one scope, no actor
/// running, an empty message log, no pending bubble.
fn serveResetToTop(evaluator: *Evaluator) void {
    evaluator.env.popTo(1);
    evaluator.actor_ctx = null;
    evaluator.msg_log_count = 0;
    evaluator.bubble_reason = null;
    evaluator.bubble_line = 0;
    evaluator.bubble_col = 0;
    evaluator.call_depth = 0;
}

/// The control socket: clients send Blimp source ending in a NUL byte and get
/// the output back ending in one. A message that starts with ':' is a
/// command instead (`:stats`).
const Control = struct {
    listen_fd: c_int = -1,
    clients: [8]Client = [_]Client{.{}} ** 8,

    const Client = struct {
        fd: c_int = -1,
        buf: std.ArrayListUnmanaged(u8) = .empty,
    };

    fn open(path: []const u8) Control {
        var c = Control{};
        const fd = std.c.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
        if (fd < 0) {
            std.debug.print("[serve] no control socket: socket() failed\n", .{});
            return c;
        }
        var addr = std.mem.zeroes(std.posix.sockaddr.un);
        addr.family = std.posix.AF.UNIX;
        if (path.len >= addr.path.len) {
            std.debug.print("[serve] no control socket: path too long\n", .{});
            _ = std.c.close(fd);
            return c;
        }
        @memcpy(addr.path[0..path.len], path);
        var zpath: [256]u8 = undefined;
        @memcpy(zpath[0..path.len], path);
        zpath[path.len] = 0;
        _ = std.c.unlink(@ptrCast(&zpath)); // a socket left by a previous run
        if (std.c.bind(fd, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.un)) < 0 or std.c.listen(fd, 4) < 0) {
            std.debug.print("[serve] no control socket: cannot bind {s}\n", .{path});
            _ = std.c.close(fd);
            return c;
        }
        _ = std.c.chmod(@ptrCast(&zpath), 0o600);
        c.listen_fd = fd;
        return c;
    }

    fn close(self: *Control) void {
        for (&self.clients) |*cl| if (cl.fd >= 0) {
            _ = std.c.close(cl.fd);
        };
        if (self.listen_fd >= 0) _ = std.c.close(self.listen_fd);
    }

    /// Accept, read, and evaluate whatever is ready, without waiting.
    fn service(self: *Control, code: std.mem.Allocator, evaluator: *Evaluator, heap_limit: *HeapLimit, stats: *ServeStats) void {
        if (self.listen_fd < 0) return;
        var pfds: [9]std.posix.pollfd = undefined;
        pfds[0] = .{ .fd = self.listen_fd, .events = std.posix.POLL.IN, .revents = 0 };
        for (self.clients, 0..) |cl, i| pfds[i + 1] = .{ .fd = cl.fd, .events = std.posix.POLL.IN, .revents = 0 };
        const ready = std.posix.poll(&pfds, 0) catch return;
        if (ready == 0) return;

        if (pfds[0].revents != 0) {
            const fd = std.c.accept(self.listen_fd, null, null);
            if (fd >= 0) {
                for (&self.clients) |*cl| {
                    if (cl.fd < 0) {
                        cl.* = .{ .fd = fd };
                        break;
                    }
                } else _ = std.c.close(fd);
            }
        }

        for (&self.clients, 0..) |*cl, i| {
            if (cl.fd < 0 or pfds[i + 1].revents == 0) continue;
            var chunk: [8192]u8 = undefined;
            const got = std.c.read(cl.fd, &chunk, chunk.len);
            if (got <= 0) {
                _ = std.c.close(cl.fd);
                cl.buf.deinit(std.heap.page_allocator);
                cl.* = .{};
                continue;
            }
            cl.buf.appendSlice(std.heap.page_allocator, chunk[0..@intCast(got)]) catch continue;
            while (std.mem.indexOfScalar(u8, cl.buf.items, 0)) |end| {
                const msg = code.dupe(u8, cl.buf.items[0..end]) catch return;
                const rest = cl.buf.items[end + 1 ..];
                std.mem.copyForwards(u8, cl.buf.items[0..rest.len], rest);
                cl.buf.shrinkRetainingCapacity(rest.len);
                var out = std.Io.Writer.Allocating.init(std.heap.page_allocator);
                defer out.deinit();
                controlEval(msg, code, evaluator, heap_limit, stats, &out.writer);
                serveResetToTop(evaluator);
                out.writer.writeByte(0) catch {};
                writeAll(cl.fd, out.written());
            }
        }
    }
};

fn writeAll(fd: c_int, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = std.c.write(fd, bytes[off..].ptr, bytes.len - off);
        if (n <= 0) return;
        off += @intCast(n);
    }
}

fn controlEval(src: []const u8, code: std.mem.Allocator, evaluator: *Evaluator, heap_limit: *HeapLimit, stats: *ServeStats, w: *std.Io.Writer) void {
    const trimmed = std.mem.trim(u8, src, " \t\r\n");
    if (std.mem.eql(u8, trimmed, ":stats")) {
        w.print("ticks {d}, errors {d}, compactions {d} ({d}ms), heap {d} bytes, live after last compaction {d}, up {d}s\n", .{
            stats.ticks, stats.errors, stats.compactions, stats.compact_ms, heap_limit.used, stats.live_after_compact, @divTrunc(nowMillis() - stats.started_ms, 1000),
        }) catch {};
        return;
    }
    var parser = Parser.init(code, src);
    const nodes = parser.parseFilePublic() catch {
        errors.parseError(src).formatPlain(w);
        return;
    };
    const saved = evaluator.source;
    evaluator.setSource(src);
    defer evaluator.setSource(saved);
    for (nodes) |node| {
        const v = evaluator.eval(node) catch {
            if (evaluator.last_error) |e| e.formatPlain(w) else w.writeAll("error\n") catch {};
            evaluator.last_error = null;
            return;
        };
        w.writeAll("=> ") catch {};
        v.format(w);
        w.writeAll("\n") catch {};
    }
}

// ── blimp --attach ───────────────────────────────────────────
//
// A prompt on a running `--serve` program: read a complete piece of Blimp
// (lines are gathered until they parse, or until a blank line), send it,
// print what comes back.

fn attach(allocator: std.mem.Allocator, path: []const u8) void {
    const fd = std.c.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
    var addr = std.mem.zeroes(std.posix.sockaddr.un);
    addr.family = std.posix.AF.UNIX;
    if (fd < 0 or path.len >= addr.path.len) {
        std.debug.print("cannot open a socket for {s}\n", .{path});
        std.process.exit(1);
    }
    @memcpy(addr.path[0..path.len], path);
    if (std.c.connect(fd, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.un)) < 0) {
        std.debug.print("nothing is serving on {s}\n", .{path});
        std.process.exit(1);
    }
    const tty = std.c.isatty(std.posix.STDIN_FILENO) != 0;
    var in_buf: [4096]u8 = undefined;
    var stdin = std.Io.File.stdin().reader(ioenv.io, &in_buf);
    var pending: std.ArrayListUnmanaged(u8) = .empty;
    defer pending.deinit(allocator);
    if (tty) std.debug.print("attached to {s}. :stats for numbers; Ctrl-D to leave.\n", .{path});
    while (true) {
        if (tty) std.debug.print("{s}", .{if (pending.items.len == 0) "site> " else "  ... "});
        // takeDelimiter consumes the newline itself, and answers a last line
        // with no newline after it as a line. takeDelimiterExclusive plus a
        // toss(1) of the newline panicked on exactly that line, since zig 0.16
        // returns it too and there was no newline to toss: `printf ':stats' |
        // blimp --attach` crashed instead of asking.
        const line = (stdin.interface.takeDelimiter('\n') catch break) orelse break;
        const blank = std.mem.trim(u8, line, " \t\r").len == 0;
        if (blank and pending.items.len == 0) continue;
        if (!blank) {
            pending.appendSlice(allocator, line) catch break;
            pending.append(allocator, '\n') catch break;
        }
        // Send when it parses, or on a blank line (let the server say why not).
        if (!blank and pending.items[0] != ':' and !parsesWhole(allocator, pending.items)) continue;
        pending.append(allocator, 0) catch break;
        writeAll(fd, pending.items);
        pending.clearRetainingCapacity();
        // print the reply up to its NUL
        var got: [8192]u8 = undefined;
        reply: while (true) {
            const n = std.c.read(fd, &got, got.len);
            if (n <= 0) {
                std.debug.print("the server closed the socket\n", .{});
                return;
            }
            const part = got[0..@intCast(n)];
            if (std.mem.indexOfScalar(u8, part, 0)) |end| {
                std.debug.print("{s}", .{part[0..end]});
                break :reply;
            }
            std.debug.print("{s}", .{part});
        }
    }
    if (pending.items.len > 0) {
        pending.append(allocator, 0) catch return;
        writeAll(fd, pending.items);
    }
}

fn parsesWhole(allocator: std.mem.Allocator, src: []const u8) bool {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), src);
    _ = parser.parseFilePublic() catch return false;
    return true;
}
