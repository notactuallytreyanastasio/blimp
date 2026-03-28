const std = @import("std");
const Lexer = @import("lexer.zig").Lexer;
const Parser = @import("parser.zig").Parser;
const ast = @import("ast.zig");
const Checker = @import("checker.zig").Checker;
const introspect = @import("introspect.zig");
const Evaluator = @import("eval.zig").Evaluator;
const Value = @import("value.zig").Value;
const errors = @import("errors.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Check for --repl flag
    if (args.len >= 2 and std.mem.eql(u8, args[1], "--repl")) {
        const is_tty = std.posix.isatty(std.posix.STDOUT_FILENO);
        if (is_tty) {
            repl(allocator);
        } else {
            replPlain(allocator);
        }
        return;
    }

    // blimp test [dir] -- discover and run *_test.blimp files
    if (args.len >= 2 and std.mem.eql(u8, args[1], "test")) {
        const test_dir = if (args.len >= 3) args[2] else "test";
        runTestDir(allocator, test_dir);
        return;
    }

    if (args.len < 2) {
        // No arguments -- enter REPL mode
        const is_tty = std.posix.isatty(std.posix.STDOUT_FILENO);
        if (is_tty) {
            repl(allocator);
        } else {
            replPlain(allocator);
        }
        return;
    }

    const source = std.fs.cwd().readFileAlloc(allocator, args[1], 1024 * 1024) catch |err| {
        std.debug.print("Error reading '{s}': {}\n", .{ args[1], err });
        std.process.exit(1);
    };
    defer allocator.free(source);

    var arena = std.heap.ArenaAllocator.init(allocator);
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
        var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
        introspect.writeJson(&stdout_writer.interface, nodes, source, arena.allocator());
        stdout_writer.interface.writeAll("\n") catch {};
        stdout_writer.interface.flush() catch {};
        return;
    }

    // Check for --ast flag (print AST without evaluating)
    if (args.len >= 3 and std.mem.eql(u8, args[2], "--ast")) {
        var stdout_buf: [4096]u8 = undefined;
        var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
        printNodes(&stdout_writer.interface, nodes, 0);
        stdout_writer.interface.flush() catch {};
        return;
    }

    // Check for --test flag (run test blocks)
    if (args.len >= 3 and std.mem.eql(u8, args[2], "--test")) {
        var evaluator = Evaluator.init(arena.allocator());
        evaluator.setSource(source);
        const start = std.time.milliTimestamp();
        const all_passed = evaluator.runTests(nodes);
        const elapsed = std.time.milliTimestamp() - start;
        var tbuf: [64]u8 = undefined;
        const timing = std.fmt.bufPrint(&tbuf, "\nFinished in {d}ms\n", .{elapsed}) catch "\n";
        std.fs.File.stderr().writeAll(timing) catch {};
        if (!all_passed) std.process.exit(1);
        return;
    }

    // Default: evaluate the file
    var evaluator = Evaluator.init(arena.allocator());
    evaluator.setSource(source);
    // Store the absolute path so the Hole operator can patch the source file
    const abs_path = std.fs.cwd().realpathAlloc(arena.allocator(), args[1]) catch args[1];
    evaluator.source_path = abs_path;
    // Build null-terminated argv for re-exec after Hole patching
    var restart_argv = try arena.allocator().alloc([:0]const u8, args.len);
    for (args, 0..) |a, i| restart_argv[i] = try arena.allocator().dupeZ(u8, a);
    evaluator.restart_argv = restart_argv;
    for (nodes) |node| {
        _ = evaluator.eval(node) catch |err| {
            if (evaluator.last_error) |blimp_err| {
                var buf: [2048]u8 = undefined;
                var fbs = std.io.fixedBufferStream(&buf);
                blimp_err.format(fbs.writer());
                std.debug.print("{s}\n", .{fbs.getWritten()});
            } else {
                std.debug.print("Runtime error: {}\n", .{err});
            }
            std.process.exit(1);
        };
    }
}

fn printNodes(writer: *std.io.Writer, nodes: []const ast.Node, indent: u32) void {
    for (nodes) |node| {
        printNode(writer, node, indent);
    }
}

fn printNode(writer: *std.io.Writer, node: ast.Node, indent: u32) void {
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

fn printInline(writer: *std.io.Writer, node: ast.Node) void {
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

fn replPlain(allocator: std.mem.Allocator) void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var evaluator = Evaluator.init(arena.allocator());

    var stdin_buf: [4096]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&stdin_buf);
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;

    stdout.writeAll("Blimp REPL (type expressions, Ctrl-D to exit)\n") catch {};
    stdout_writer.interface.flush() catch {};

    var multi_buf = std.ArrayList(u8){ .items = &.{}, .capacity = 0 };
    var depth: i32 = 0;

    while (true) {
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
                    if (evaluator.last_error) |rich_err| {
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
                if (evaluator.last_error) |rich_err| {
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
fn runTestDir(gpa: std.mem.Allocator, dir_path: []const u8) void {
    var test_arena = std.heap.ArenaAllocator.init(gpa);
    defer test_arena.deinit();
    const allocator = test_arena.allocator();
    const stderr = std.fs.File.stderr();
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch {
        stderr.writeAll("Could not open test directory: ") catch {};
        stderr.writeAll(dir_path) catch {};
        stderr.writeAll("\n") catch {};
        std.process.exit(1);
    };
    defer dir.close();

    var files: std.ArrayList([]const u8) = .empty;
    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.endsWith(u8, entry.name, "_test.blimp")) {
            const name = allocator.dupe(u8, entry.name) catch continue;
            files.append(allocator, name) catch continue;
        }
    }

    if (files.items.len == 0) {
        stderr.writeAll("No *_test.blimp files found in ") catch {};
        stderr.writeAll(dir_path) catch {};
        stderr.writeAll("/\n") catch {};
        return;
    }

    // Sort for deterministic order
    std.mem.sort([]const u8, files.items, {}, struct {
        fn cmp(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.cmp);

    stderr.writeAll("\n") catch {};
    var any_failed = false;
    const start_time = std.time.milliTimestamp();

    for (files.items) |filename| {
        // Build full path
        const full_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, filename }) catch continue;

        stderr.writeAll("\x1b[1m") catch {};
        stderr.writeAll(filename) catch {};
        stderr.writeAll("\x1b[0m\n") catch {};

        const source = std.fs.cwd().readFileAlloc(allocator, full_path, 1024 * 1024) catch {
            stderr.writeAll("  \x1b[31mfailed to read file\x1b[0m\n") catch {};
            any_failed = true;
            continue;
        };

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        var parser = Parser.init(arena.allocator(), source);
        const nodes = parser.parseFile() catch {
            stderr.writeAll("  \x1b[31mparse error\x1b[0m\n") catch {};
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

    const elapsed = std.time.milliTimestamp() - start_time;
    var buf: [64]u8 = undefined;
    const timing = std.fmt.bufPrint(&buf, "\nFinished in {d}ms\n", .{elapsed}) catch "\n";
    stderr.writeAll(timing) catch {};

    if (any_failed) std.process.exit(1);
}

fn repl(allocator: std.mem.Allocator) void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var evaluator = Evaluator.init(arena.allocator());

    var stdin_buf: [4096]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&stdin_buf);
    var stdout_buf: [8192]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;

    var history = std.ArrayList(HistoryEntry){ .items = &.{}, .capacity = 0 };

    // Get terminal size
    const term_size = getTerminalSize();
    const total_cols = term_size.cols;
    const total_rows = term_size.rows;
    const left_cols = (total_cols * 3) / 4;
    const right_cols = total_cols - left_cols - 1; // -1 for border

    // Initial draw
    drawScreen(stdout, &history, &evaluator, arena.allocator(), total_rows, left_cols, right_cols);
    stdout_writer.interface.flush() catch {};

    var multi_buf = std.ArrayList(u8){ .items = &.{}, .capacity = 0 };
    var depth: i32 = 0;

    while (true) {
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

        // Decide whether to use parseFile or parseStatement
        const is_multiline = std.mem.indexOf(u8, source, "\n") != null;

        if (is_multiline) {
            var parser = Parser.init(arena.allocator(), source);
            const nodes = parser.parseFilePublic() catch {
                const pe = @import("errors.zig").parseError(source);
                const err_text = formatBlimpError(pe, arena.allocator());
                history.append(arena.allocator(), .{ .kind = .err, .text = err_text }) catch {};
                drawScreen(stdout, &history, &evaluator, arena.allocator(), total_rows, left_cols, right_cols);
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
                drawScreen(stdout, &history, &evaluator, arena.allocator(), total_rows, left_cols, right_cols);
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
                drawScreen(stdout, &history, &evaluator, arena.allocator(), total_rows, left_cols, right_cols);
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
                drawScreen(stdout, &history, &evaluator, arena.allocator(), total_rows, left_cols, right_cols);
                stdout_writer.interface.flush() catch {};
                continue;
            };

            // Format result to string
            const result_text = formatValue(result, arena.allocator());
            history.append(arena.allocator(), .{ .kind = .output, .text = result_text }) catch {};
        }

        drawScreen(stdout, &history, &evaluator, arena.allocator(), total_rows, left_cols, right_cols);
        stdout_writer.interface.flush() catch {};
    }

    // Restore terminal: move to bottom, clear
    moveCursor(stdout, total_rows, 1);
    stdout.writeAll("\n") catch {};
    stdout_writer.interface.flush() catch {};
}

fn formatValue(val: *const @import("value.zig").Value, alloc: std.mem.Allocator) []const u8 {
    var buf = std.ArrayList(u8){ .items = &.{}, .capacity = 0 };
    val.format(buf.writer(alloc));
    return buf.items;
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
    alloc: std.mem.Allocator,
    total_rows: u32,
    left_cols: u32,
    right_cols: u32,
) void {
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
