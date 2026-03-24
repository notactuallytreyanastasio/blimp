const std = @import("std");
const ast = @import("ast.zig");
const Node = ast.Node;
const Loc = ast.Loc;

/// JSON introspection output for REPL sidebar consumption.
/// Walks the AST and produces a structured JSON representation of all
/// actors, state fields, handlers, and Holes in a Blimp program.

/// Represents a Hole found during introspection.
const HoleInfo = struct {
    line: u32,
    col: u32,
    directive: ?[]const u8,
    context: []const u8,
};

/// Represents a state field for JSON output.
const StateField = struct {
    name: []const u8,
    type_name: []const u8,
    default_str: []const u8,
};

/// Represents a handler parameter for JSON output.
const ParamInfo = struct {
    name: []const u8,
    type_name: []const u8,
};

/// Represents a handler for JSON output.
const HandlerInfo = struct {
    message: []const u8,
    params: []const ParamInfo,
    return_type: ?[]const u8,
    guard: ?[]const u8,
    bubbles: ?[]const u8,
};

/// Represents an actor for JSON output.
const ActorInfo = struct {
    name: []const u8,
    state: []const StateField,
    handlers: []const HandlerInfo,
    holes: []const HoleInfo,
};

/// Write JSON introspection output for a parsed Blimp file.
/// Takes the top-level AST nodes and the original source (for extracting
/// hole directive comments).
pub fn writeJson(writer: anytype, nodes: []const Node, source: []const u8, allocator: std.mem.Allocator) void {
    var actors: std.ArrayList(ActorInfo) = .empty;

    for (nodes) |node| {
        if (node.kind == .actor_def) {
            const info = collectActor(node.kind.actor_def, source, allocator);
            actors.append(allocator, info) catch {};
        }
    }

    writeActorsJson(writer, actors.items);
}

/// Collect all information about an actor.
fn collectActor(actor: Node.ActorDef, source: []const u8, allocator: std.mem.Allocator) ActorInfo {
    var state_fields: std.ArrayList(StateField) = .empty;
    var handlers: std.ArrayList(HandlerInfo) = .empty;
    var holes: std.ArrayList(HoleInfo) = .empty;

    for (actor.body) |stmt| {
        switch (stmt.kind) {
            .state_def => |s| {
                for (s.fields) |f| {
                    const default_str = if (f.default_value != null) exprToString(f.value, allocator) else "";
                    state_fields.append(allocator, .{
                        .name = f.key,
                        .type_name = f.type_name orelse "untyped",
                        .default_str = default_str,
                    }) catch {};
                }
            },
            .message_handler => |h| {
                var params: std.ArrayList(ParamInfo) = .empty;
                for (h.params) |p| {
                    params.append(allocator, .{
                        .name = p.name,
                        .type_name = p.type_name orelse "untyped",
                    }) catch {};
                }

                var guard_str: ?[]const u8 = null;
                if (h.guard) |guard| {
                    guard_str = exprToString(guard.*, allocator);
                }

                handlers.append(allocator, .{
                    .message = h.name,
                    .params = params.toOwnedSlice(allocator) catch &.{},
                    .return_type = h.return_type,
                    .guard = guard_str,
                    .bubbles = h.bubble_strategy,
                }) catch {};

                // Collect holes from handler body
                collectHoles(h.body, source, &holes, allocator, h.name, actor.name);
            },
            else => {},
        }
    }

    return .{
        .name = actor.name,
        .state = state_fields.toOwnedSlice(allocator) catch &.{},
        .handlers = handlers.toOwnedSlice(allocator) catch &.{},
        .holes = holes.toOwnedSlice(allocator) catch &.{},
    };
}

/// Recursively collect holes from a list of AST nodes.
fn collectHoles(
    nodes: []const Node,
    source: []const u8,
    holes: *std.ArrayList(HoleInfo),
    allocator: std.mem.Allocator,
    handler_name: []const u8,
    actor_name: []const u8,
) void {
    for (nodes) |node| {
        collectHolesFromNode(node, source, holes, allocator, handler_name, actor_name);
    }
}

/// Recursively collect holes from a single AST node, descending into all children.
fn collectHolesFromNode(
    node: Node,
    source: []const u8,
    holes: *std.ArrayList(HoleInfo),
    allocator: std.mem.Allocator,
    handler_name: []const u8,
    actor_name: []const u8,
) void {
    switch (node.kind) {
        .hole => |h| {
            // Extract directive from source comment on the same line
            const directive = if (h.directive) |d| d else extractDirectiveFromSource(source, node.loc);
            const context = buildContext(allocator, handler_name, actor_name);
            holes.append(allocator, .{
                .line = node.loc.line,
                .col = node.loc.col,
                .directive = directive,
                .context = context,
            }) catch {};
        },
        .situation => |s| {
            // Check subject for holes
            collectHolesFromNode(s.subject.*, source, holes, allocator, handler_name, actor_name);
            // Check branches
            for (s.branches) |branch| {
                if (branch.pattern) |pat| {
                    collectHolesFromNode(pat.*, source, holes, allocator, handler_name, actor_name);
                }
                collectHoles(branch.body, source, holes, allocator, handler_name, actor_name);
            }
        },
        .case_expr => |c| {
            collectHolesFromNode(c.subject.*, source, holes, allocator, handler_name, actor_name);
            for (c.branches) |branch| {
                if (branch.pattern) |pat| {
                    collectHolesFromNode(pat.*, source, holes, allocator, handler_name, actor_name);
                }
                collectHoles(branch.body, source, holes, allocator, handler_name, actor_name);
            }
        },
        .reply_stmt => |r| {
            collectHolesFromNode(r.value.*, source, holes, allocator, handler_name, actor_name);
        },
        .assign_stmt => |a| {
            collectHolesFromNode(a.value.*, source, holes, allocator, handler_name, actor_name);
        },
        .become_stmt => |b| {
            for (b.fields) |f| {
                collectHolesFromNode(f.value, source, holes, allocator, handler_name, actor_name);
            }
        },
        .binary_op => |op| {
            collectHolesFromNode(op.left.*, source, holes, allocator, handler_name, actor_name);
            collectHolesFromNode(op.right.*, source, holes, allocator, handler_name, actor_name);
        },
        .unary_op => |op| {
            collectHolesFromNode(op.operand.*, source, holes, allocator, handler_name, actor_name);
        },
        .func_call => |c| {
            for (c.args) |arg| {
                collectHolesFromNode(arg, source, holes, allocator, handler_name, actor_name);
            }
        },
        .pipe_expr => |p| {
            collectHolesFromNode(p.left.*, source, holes, allocator, handler_name, actor_name);
            collectHolesFromNode(p.right.*, source, holes, allocator, handler_name, actor_name);
        },
        .list_lit => |l| {
            for (l.elements) |elem| {
                collectHolesFromNode(elem, source, holes, allocator, handler_name, actor_name);
            }
            if (l.tail) |t| {
                collectHolesFromNode(t.*, source, holes, allocator, handler_name, actor_name);
            }
        },
        .tuple_lit => |t| {
            for (t.elements) |elem| {
                collectHolesFromNode(elem, source, holes, allocator, handler_name, actor_name);
            }
        },
        .map_lit => |m| {
            for (m.entries) |entry| {
                collectHolesFromNode(entry.value, source, holes, allocator, handler_name, actor_name);
            }
        },
        .dot_access => |d| {
            collectHolesFromNode(d.object.*, source, holes, allocator, handler_name, actor_name);
        },
        .message_send => |ms| {
            collectHolesFromNode(ms.target.*, source, holes, allocator, handler_name, actor_name);
            for (ms.args) |arg| {
                collectHolesFromNode(arg, source, holes, allocator, handler_name, actor_name);
            }
        },
        .orelse_expr => |oe| {
            collectHolesFromNode(oe.try_expr.*, source, holes, allocator, handler_name, actor_name);
            collectHolesFromNode(oe.fallback.*, source, holes, allocator, handler_name, actor_name);
        },
        else => {},
    }
}

/// Build a human-readable context string for a hole.
fn buildContext(allocator: std.mem.Allocator, handler_name: []const u8, actor_name: []const u8) []const u8 {
    return std.fmt.allocPrint(allocator, "in :{s} handler of {s}", .{ handler_name, actor_name }) catch "unknown context";
}

/// Extract a directive comment from source text at a given location.
/// Looks for `# ...` text on the same line as the hole, after the `_` token.
fn extractDirectiveFromSource(source: []const u8, loc: Loc) ?[]const u8 {
    // Find the start of the line containing the hole
    var line_num: u32 = 1;
    var line_start: usize = 0;
    var i: usize = 0;
    while (i < source.len) : (i += 1) {
        if (line_num == loc.line) break;
        if (source[i] == '\n') {
            line_num += 1;
            line_start = i + 1;
        }
    }

    // Now line_start is the beginning of the hole's line.
    // Find the end of the line.
    var line_end = line_start;
    while (line_end < source.len and source[line_end] != '\n') : (line_end += 1) {}

    const line = source[line_start..line_end];

    // Look for # in the line after the hole position
    const hole_col_idx = if (loc.col > 0) loc.col - 1 else 0;
    if (hole_col_idx >= line.len) return null;

    // Search for # after the hole
    const after_hole = line[hole_col_idx..];
    const hash_pos = std.mem.indexOf(u8, after_hole, "#") orelse return null;
    const comment_start = hash_pos + 1;
    if (comment_start >= after_hole.len) return null;

    const comment_text = std.mem.trim(u8, after_hole[comment_start..], " \t\r");
    if (comment_text.len == 0) return null;

    // Strip "Hole:" or "Hole: " prefix if present
    if (std.mem.startsWith(u8, comment_text, "Hole:")) {
        const rest = std.mem.trim(u8, comment_text[5..], " ");
        if (rest.len > 0) return rest;
        return null;
    }

    return comment_text;
}

/// Convert an expression node to a human-readable string representation.
fn exprToString(node: Node, allocator: std.mem.Allocator) []const u8 {
    return switch (node.kind) {
        .integer_lit => |il| std.fmt.allocPrint(allocator, "{d}", .{il.value}) catch "?",
        .float_lit => |fl| std.fmt.allocPrint(allocator, "{d}", .{fl.value}) catch "?",
        .string_lit => |sl| sl.value,
        .atom_lit => |al| std.fmt.allocPrint(allocator, ":{s}", .{al.name}) catch "?",
        .bool_lit => |bl| if (bl.value) "true" else "false",
        .nil_lit => "nil",
        .identifier => |id| id.name,
        .list_lit => |ll| {
            if (ll.elements.len == 0 and ll.tail == null) return "[]";
            return "[...]";
        },
        .tuple_lit => "{...}",
        .map_lit => |ml| {
            if (ml.entries.len == 0) return "%{}";
            return "%{...}";
        },
        .func_call => |cl| {
            var buf: std.ArrayList(u8) = .empty;
            buf.appendSlice(allocator, cl.name) catch return cl.name;
            buf.append(allocator, '(') catch return cl.name;
            for (cl.args, 0..) |arg, idx| {
                if (idx > 0) buf.appendSlice(allocator, ", ") catch {};
                buf.appendSlice(allocator, exprToString(arg, allocator)) catch {};
            }
            buf.append(allocator, ')') catch return cl.name;
            return buf.toOwnedSlice(allocator) catch cl.name;
        },
        .binary_op => |op| {
            const left_str = exprToString(op.left.*, allocator);
            const op_str: []const u8 = switch (op.op) {
                .add => "+",
                .sub => "-",
                .mul => "*",
                .div => "/",
                .eq => "==",
                .neq => "!=",
                .lt => "<",
                .gt => ">",
                .lte => "<=",
                .gte => ">=",
                .and_op => "&&",
                .or_op => "||",
                .concat => "++",
            };
            const right_str = exprToString(op.right.*, allocator);
            return std.fmt.allocPrint(allocator, "{s} {s} {s}", .{ left_str, op_str, right_str }) catch "?";
        },
        .dot_access => |da| {
            const obj_str = exprToString(da.object.*, allocator);
            return std.fmt.allocPrint(allocator, "{s}.{s}", .{ obj_str, da.field }) catch "?";
        },
        .unary_op => |op| {
            const operand_str = exprToString(op.operand.*, allocator);
            const op_str: []const u8 = switch (op.op) {
                .negate => "-",
                .not => "!",
            };
            return std.fmt.allocPrint(allocator, "{s}{s}", .{ op_str, operand_str }) catch "?";
        },
        else => "?",
    };
}

// ============================================================
// JSON writing
// ============================================================

/// Write the complete actors array as JSON.
fn writeActorsJson(writer: anytype, actors: []const ActorInfo) void {
    writer.writeAll("{\"actors\":[") catch {};
    for (actors, 0..) |actor, i| {
        if (i > 0) writer.writeAll(",") catch {};
        writeActorJson(writer, actor);
    }
    writer.writeAll("]}") catch {};
}

/// Write a single actor as JSON.
fn writeActorJson(writer: anytype, actor: ActorInfo) void {
    writer.writeAll("{\"name\":") catch {};
    writeJsonString(writer, actor.name);

    writer.writeAll(",\"state\":[") catch {};
    for (actor.state, 0..) |field, i| {
        if (i > 0) writer.writeAll(",") catch {};
        writeStateFieldJson(writer, field);
    }

    writer.writeAll("],\"handlers\":[") catch {};
    for (actor.handlers, 0..) |handler, i| {
        if (i > 0) writer.writeAll(",") catch {};
        writeHandlerJson(writer, handler);
    }

    writer.writeAll("],\"holes\":[") catch {};
    for (actor.holes, 0..) |hole, i| {
        if (i > 0) writer.writeAll(",") catch {};
        writeHoleJson(writer, hole);
    }
    writer.writeAll("]}") catch {};
}

/// Write a state field as JSON.
fn writeStateFieldJson(writer: anytype, field: StateField) void {
    writer.writeAll("{\"name\":") catch {};
    writeJsonString(writer, field.name);
    writer.writeAll(",\"type\":") catch {};
    writeJsonString(writer, field.type_name);
    writer.writeAll(",\"default\":") catch {};
    writeJsonString(writer, field.default_str);
    writer.writeAll("}") catch {};
}

/// Write a handler as JSON.
fn writeHandlerJson(writer: anytype, handler: HandlerInfo) void {
    writer.writeAll("{\"message\":") catch {};
    writeJsonString(writer, handler.message);

    writer.writeAll(",\"params\":[") catch {};
    for (handler.params, 0..) |param, i| {
        if (i > 0) writer.writeAll(",") catch {};
        writer.writeAll("{\"name\":") catch {};
        writeJsonString(writer, param.name);
        writer.writeAll(",\"type\":") catch {};
        writeJsonString(writer, param.type_name);
        writer.writeAll("}") catch {};
    }

    writer.writeAll("],\"return_type\":") catch {};
    if (handler.return_type) |rt| {
        writeJsonString(writer, rt);
    } else {
        writer.writeAll("null") catch {};
    }

    writer.writeAll(",\"guard\":") catch {};
    if (handler.guard) |g| {
        writeJsonString(writer, g);
    } else {
        writer.writeAll("null") catch {};
    }

    writer.writeAll(",\"bubbles\":") catch {};
    if (handler.bubbles) |b| {
        writeJsonString(writer, b);
    } else {
        writer.writeAll("null") catch {};
    }

    writer.writeAll("}") catch {};
}

/// Write a hole as JSON.
fn writeHoleJson(writer: anytype, hole: HoleInfo) void {
    writer.writeAll("{\"line\":") catch {};
    writer.print("{d}", .{hole.line}) catch {};
    writer.writeAll(",\"col\":") catch {};
    writer.print("{d}", .{hole.col}) catch {};

    writer.writeAll(",\"directive\":") catch {};
    if (hole.directive) |d| {
        writeJsonString(writer, d);
    } else {
        writer.writeAll("null") catch {};
    }

    writer.writeAll(",\"context\":") catch {};
    writeJsonString(writer, hole.context);
    writer.writeAll("}") catch {};
}

/// Write a JSON-escaped string value (with surrounding quotes).
fn writeJsonString(writer: anytype, s: []const u8) void {
    writer.writeAll("\"") catch {};
    for (s) |c| {
        switch (c) {
            '"' => writer.writeAll("\\\"") catch {},
            '\\' => writer.writeAll("\\\\") catch {},
            '\n' => writer.writeAll("\\n") catch {},
            '\r' => writer.writeAll("\\r") catch {},
            '\t' => writer.writeAll("\\t") catch {},
            else => {
                if (c < 0x20) {
                    writer.print("\\u{x:0>4}", .{c}) catch {};
                } else {
                    writer.writeByte(c) catch {};
                }
            },
        }
    }
    writer.writeAll("\"") catch {};
}

// ============================================================
// Tests
// ============================================================

fn parseSource(allocator: std.mem.Allocator, source: []const u8) []const Node {
    var parser = @import("parser.zig").Parser.init(allocator, source);
    return parser.parseFile() catch &.{};
}

fn collectJsonOutput(alloc: std.mem.Allocator, source: []const u8) []const u8 {
    const nodes = parseSource(alloc, source);
    var output: std.ArrayList(u8) = .empty;
    writeJson(output.writer(alloc), nodes, source, alloc);
    return output.items;
}

test "introspect simple actor with state and handler" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\actor Counter do
        \\  state count: Int :: 0
        \\  on :increment do
        \\    become count: count + 1
        \\    reply :ok
        \\  end
        \\end
    ;

    const json = collectJsonOutput(alloc, source);

    // Verify it contains the actor name
    try std.testing.expect(std.mem.indexOf(u8, json, "\"Counter\"") != null);
    // Verify state field
    try std.testing.expect(std.mem.indexOf(u8, json, "\"count\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"Int\"") != null);
    // Verify handler
    try std.testing.expect(std.mem.indexOf(u8, json, "\"increment\"") != null);
}

test "introspect actor with typed handler params and return type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\actor Cart do
        \\  state items: [Item] :: []
        \\  on :add(item: Item) -> Atom do
        \\    reply :ok
        \\  end
        \\end
    ;

    const json = collectJsonOutput(alloc, source);

    // Actor name
    try std.testing.expect(std.mem.indexOf(u8, json, "\"Cart\"") != null);
    // State field with list type
    try std.testing.expect(std.mem.indexOf(u8, json, "\"[Item]\"") != null);
    // Handler name
    try std.testing.expect(std.mem.indexOf(u8, json, "\"add\"") != null);
    // Param type
    try std.testing.expect(std.mem.indexOf(u8, json, "\"Item\"") != null);
    // Return type
    try std.testing.expect(std.mem.indexOf(u8, json, "\"Atom\"") != null);
}

test "introspect actor with guard and bubbles" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\actor Checkout do
        \\  state total: Int :: 0
        \\  on :charge(payment: Int) -> Atom when payment > 0 bubbles(CascadeBubble) do
        \\    reply :ok
        \\  end
        \\end
    ;

    const json = collectJsonOutput(alloc, source);

    // Guard should be present (not null)
    try std.testing.expect(std.mem.indexOf(u8, json, "\"guard\":null") == null);
    // Guard should contain the expression
    try std.testing.expect(std.mem.indexOf(u8, json, "payment") != null);
    // Bubbles strategy
    try std.testing.expect(std.mem.indexOf(u8, json, "\"CascadeBubble\"") != null);
}

test "introspect multiple actors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\actor Shop.Inventory do
        \\  state items: [Item] :: []
        \\  on :count -> Int do
        \\    reply length(items)
        \\  end
        \\end
        \\actor Shop.Checkout do
        \\  state total: Int :: 0
        \\  on :charge(payment: Int) -> Atom do
        \\    reply :ok
        \\  end
        \\end
    ;

    const json = collectJsonOutput(alloc, source);

    // Both actors present
    try std.testing.expect(std.mem.indexOf(u8, json, "\"Shop.Inventory\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"Shop.Checkout\"") != null);
}

test "introspect hole in situation branch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\actor Test do
        \\  state count: Int :: 0
        \\  on :process(event: Event) -> Atom do
        \\    situation event do
        \\      :known -> reply :ok
        \\      _ -> reply :unknown
        \\    end
        \\  end
        \\end
    ;

    const json = collectJsonOutput(alloc, source);

    // Should have the actor
    try std.testing.expect(std.mem.indexOf(u8, json, "\"Test\"") != null);
    // Should have the handler
    try std.testing.expect(std.mem.indexOf(u8, json, "\"process\"") != null);
}

test "introspect produces valid JSON structure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\actor A do
        \\  state x: Int :: 0
        \\  on :get -> Int do
        \\    reply x
        \\  end
        \\end
    ;

    const json = collectJsonOutput(alloc, source);

    // Should start and end correctly
    try std.testing.expect(std.mem.startsWith(u8, json, "{\"actors\":["));
    try std.testing.expect(std.mem.endsWith(u8, json, "]}"));
}

test "introspect empty file produces empty actors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source = "";
    const json = collectJsonOutput(alloc, source);

    try std.testing.expectEqualStrings("{\"actors\":[]}", json);
}

test "extractDirectiveFromSource finds comment on hole line" {
    const source = "      _ # Hole: handle unknown events\n  end\n";
    const loc = Loc{ .line = 1, .col = 7 };
    const directive = extractDirectiveFromSource(source, loc);
    try std.testing.expect(directive != null);
    try std.testing.expectEqualStrings("handle unknown events", directive.?);
}

test "extractDirectiveFromSource returns null when no comment" {
    const source = "      _ -> reply :ok\n";
    const loc = Loc{ .line = 1, .col = 7 };
    const directive = extractDirectiveFromSource(source, loc);
    try std.testing.expect(directive == null);
}

test "extractDirectiveFromSource handles comment without Hole prefix" {
    const source = "  _ # some note about this branch\n";
    const loc = Loc{ .line = 1, .col = 3 };
    const directive = extractDirectiveFromSource(source, loc);
    try std.testing.expect(directive != null);
    try std.testing.expectEqualStrings("some note about this branch", directive.?);
}

test "writeJsonString escapes special characters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var output: std.ArrayList(u8) = .empty;
    writeJsonString(output.writer(alloc), "hello \"world\"\nline2");
    const result = output.items;

    try std.testing.expectEqualStrings("\"hello \\\"world\\\"\\nline2\"", result);
}

test "exprToString covers basic cases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Integer
    const int_node = Node{ .kind = .{ .integer_lit = .{ .value = 42 } }, .loc = .{ .line = 1, .col = 1 } };
    try std.testing.expectEqualStrings("42", exprToString(int_node, alloc));

    // Atom
    const atom_node = Node{ .kind = .{ .atom_lit = .{ .name = "ok" } }, .loc = .{ .line = 1, .col = 1 } };
    try std.testing.expectEqualStrings(":ok", exprToString(atom_node, alloc));

    // Bool
    const bool_node = Node{ .kind = .{ .bool_lit = .{ .value = true } }, .loc = .{ .line = 1, .col = 1 } };
    try std.testing.expectEqualStrings("true", exprToString(bool_node, alloc));

    // Empty list
    const empty_list = Node{ .kind = .{ .list_lit = .{ .elements = &.{}, .tail = null } }, .loc = .{ .line = 1, .col = 1 } };
    try std.testing.expectEqualStrings("[]", exprToString(empty_list, alloc));

    // Nil
    const nil_node = Node{ .kind = .{ .nil_lit = {} }, .loc = .{ .line = 1, .col = 1 } };
    try std.testing.expectEqualStrings("nil", exprToString(nil_node, alloc));
}

test "exprToString renders binary expressions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const left = alloc.create(Node) catch unreachable;
    left.* = Node{ .kind = .{ .identifier = .{ .name = "payment" } }, .loc = .{ .line = 1, .col = 1 } };
    const right = alloc.create(Node) catch unreachable;
    right.* = Node{ .kind = .{ .integer_lit = .{ .value = 0 } }, .loc = .{ .line = 1, .col = 11 } };

    const bin_node = Node{
        .kind = .{ .binary_op = .{ .op = .gt, .left = left, .right = right } },
        .loc = .{ .line = 1, .col = 9 },
    };
    try std.testing.expectEqualStrings("payment > 0", exprToString(bin_node, alloc));
}
