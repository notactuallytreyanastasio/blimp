const std = @import("std");
const Lexer = @import("lexer.zig").Lexer;
const Parser = @import("parser.zig").Parser;
const ast = @import("ast.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: blimp <file.blimp>\n", .{});
        std.process.exit(1);
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
                    writer.print("{s}", .{p}) catch {};
                }
                writer.print(")", .{}) catch {};
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
        else => writer.print(" ???", .{}) catch {},
    }
}
