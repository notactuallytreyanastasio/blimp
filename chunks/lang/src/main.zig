const std = @import("std");
const Lexer = @import("lexer.zig").Lexer;
const Parser = @import("parser.zig").Parser;
const ast = @import("ast.zig");
const Checker = @import("checker.zig").Checker;
const introspect = @import("introspect.zig");
const Evaluator = @import("eval.zig").Evaluator;
const Value = @import("value.zig").Value;

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

    // Type check
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

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    printNodes(&stdout_writer.interface, nodes, 0);
    stdout_writer.interface.flush() catch {};
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
        else => writer.print(" ???", .{}) catch {},
    }
}

/// Count the net depth change from `do` and `end` keywords in a line.
/// Uses simple word-boundary checking.
fn countDepthChange(line: []const u8) i32 {
    var delta: i32 = 0;
    var i: usize = 0;
    while (i < line.len) {
        // Skip whitespace
        if (line[i] == ' ' or line[i] == '\t' or line[i] == '\n' or line[i] == '\r') {
            i += 1;
            continue;
        }
        // Check for "do" keyword at word boundary
        if (i + 2 <= line.len and std.mem.eql(u8, line[i .. i + 2], "do")) {
            const before_ok = (i == 0) or (line[i - 1] == ' ' or line[i - 1] == '\t' or line[i - 1] == '\n' or line[i - 1] == ')');
            const after_ok = (i + 2 >= line.len) or (line[i + 2] == ' ' or line[i + 2] == '\t' or line[i + 2] == '\n' or line[i + 2] == '\r');
            if (before_ok and after_ok) {
                delta += 1;
                i += 2;
                continue;
            }
        }
        // Check for "end" keyword at word boundary
        if (i + 3 <= line.len and std.mem.eql(u8, line[i .. i + 3], "end")) {
            const before_ok = (i == 0) or (line[i - 1] == ' ' or line[i - 1] == '\t' or line[i - 1] == '\n');
            const after_ok = (i + 3 >= line.len) or (line[i + 3] == ' ' or line[i + 3] == '\t' or line[i + 3] == '\n' or line[i + 3] == '\r');
            if (before_ok and after_ok) {
                delta -= 1;
                i += 3;
                continue;
            }
        }
        // Skip to next whitespace (move past current word)
        while (i < line.len and line[i] != ' ' and line[i] != '\t' and line[i] != '\n' and line[i] != '\r') {
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
            stdout.writeAll("  ... ") catch break;
        } else {
            stdout.writeAll("blimp> ") catch break;
        }
        stdout_writer.interface.flush() catch break;

        const line = stdin_reader.interface.takeDelimiterExclusive('\n') catch break;
        stdin_reader.interface.toss(1);
        if (line.len == 0 and depth == 0) continue;

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
        if (bindings.len > 0) {
            stdout.writeAll("  ┌─ state ─────────────────────\n") catch {};
            for (bindings) |binding| {
                stdout.print("  │ {s} = ", .{binding.name}) catch {};
                binding.val.format(&stdout_writer.interface);
                stdout.writeAll("\n") catch {};
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
    drawScreen(stdout, &history, &evaluator.env, arena.allocator(), total_rows, left_cols, right_cols);
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
                drawScreen(stdout, &history, &evaluator.env, arena.allocator(), total_rows, left_cols, right_cols);
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
                drawScreen(stdout, &history, &evaluator.env, arena.allocator(), total_rows, left_cols, right_cols);
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
                drawScreen(stdout, &history, &evaluator.env, arena.allocator(), total_rows, left_cols, right_cols);
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
                drawScreen(stdout, &history, &evaluator.env, arena.allocator(), total_rows, left_cols, right_cols);
                stdout_writer.interface.flush() catch {};
                continue;
            };

            // Format result to string
            const result_text = formatValue(result, arena.allocator());
            history.append(arena.allocator(), .{ .kind = .output, .text = result_text }) catch {};
        }

        drawScreen(stdout, &history, &evaluator.env, arena.allocator(), total_rows, left_cols, right_cols);
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
    env: *const @import("env.zig").Environment,
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
    const bindings = env.allBindings(alloc);
    for (bindings, 0..) |binding, i| {
        const row: u32 = @intCast(i + 3);
        if (row >= content_rows) break;
        moveCursor(writer, row, left_cols + 3);
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
