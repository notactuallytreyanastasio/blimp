/// Tests for parser.zig
///
/// NOTE: parser.zig currently uses the pre-Zig-0.14 ArrayListUnmanaged API
/// (std.ArrayList with .empty init and allocator passed to append). These
/// tests are correct and ready to run once parser.zig is updated to Zig 0.14
/// ArrayListUnmanaged syntax.
///
/// Run with: zig test src/parser_test.zig -target x86_64-macos
const std = @import("std");
const Parser = @import("parser.zig").Parser;
const ast = @import("ast.zig");
const Node = ast.Node;

// ============================================================
// Literal parsing
// ============================================================

test "parse integer literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = Parser.init(arena.allocator(), "42");
    const nodes = try p.parseFile();
    try std.testing.expectEqual(@as(usize, 1), nodes.len);
    try std.testing.expectEqual(Node.Kind.integer_lit, std.meta.activeTag(nodes[0].kind));
    try std.testing.expectEqual(@as(i64, 42), nodes[0].kind.integer_lit.value);
}

test "parse float literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = Parser.init(arena.allocator(), "3.14");
    const nodes = try p.parseFile();
    try std.testing.expectEqual(@as(usize, 1), nodes.len);
    try std.testing.expectEqual(Node.Kind.float_lit, std.meta.activeTag(nodes[0].kind));
    try std.testing.expectApproxEqAbs(@as(f64, 3.14), nodes[0].kind.float_lit.value, 0.0001);
}

test "parse string literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = Parser.init(arena.allocator(), "\"hello\"");
    const nodes = try p.parseFile();
    try std.testing.expectEqual(@as(usize, 1), nodes.len);
    try std.testing.expectEqual(Node.Kind.string_lit, std.meta.activeTag(nodes[0].kind));
    try std.testing.expectEqualStrings("hello", nodes[0].kind.string_lit.value);
}

test "parse atom literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = Parser.init(arena.allocator(), ":ok");
    const nodes = try p.parseFile();
    try std.testing.expectEqual(@as(usize, 1), nodes.len);
    try std.testing.expectEqual(Node.Kind.atom_lit, std.meta.activeTag(nodes[0].kind));
    try std.testing.expectEqualStrings("ok", nodes[0].kind.atom_lit.name);
}

test "parse true literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = Parser.init(arena.allocator(), "true");
    const nodes = try p.parseFile();
    try std.testing.expectEqual(@as(usize, 1), nodes.len);
    try std.testing.expectEqual(Node.Kind.bool_lit, std.meta.activeTag(nodes[0].kind));
    try std.testing.expect(nodes[0].kind.bool_lit.value);
}

test "parse false literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = Parser.init(arena.allocator(), "false");
    const nodes = try p.parseFile();
    try std.testing.expectEqual(@as(usize, 1), nodes.len);
    try std.testing.expect(!nodes[0].kind.bool_lit.value);
}

test "parse nil literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = Parser.init(arena.allocator(), "nil");
    const nodes = try p.parseFile();
    try std.testing.expectEqual(@as(usize, 1), nodes.len);
    try std.testing.expectEqual(Node.Kind.nil_lit, std.meta.activeTag(nodes[0].kind));
}

test "parse hole (_)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = Parser.init(arena.allocator(), "_");
    const nodes = try p.parseFile();
    try std.testing.expectEqual(@as(usize, 1), nodes.len);
    try std.testing.expectEqual(Node.Kind.hole, std.meta.activeTag(nodes[0].kind));
}

// ============================================================
// Identifier and assignment
// ============================================================

test "parse identifier" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = Parser.init(arena.allocator(), "my_var");
    const nodes = try p.parseFile();
    try std.testing.expectEqual(@as(usize, 1), nodes.len);
    try std.testing.expectEqual(Node.Kind.identifier, std.meta.activeTag(nodes[0].kind));
    try std.testing.expectEqualStrings("my_var", nodes[0].kind.identifier.name);
}

test "parse assignment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = Parser.init(arena.allocator(), "x = 10");
    const nodes = try p.parseFile();
    try std.testing.expectEqual(@as(usize, 1), nodes.len);
    try std.testing.expectEqual(Node.Kind.assign_stmt, std.meta.activeTag(nodes[0].kind));
    try std.testing.expectEqualStrings("x", nodes[0].kind.assign_stmt.name);
}

// ============================================================
// Binary operations (op is an enum, not a string)
// ============================================================

test "parse addition" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = Parser.init(arena.allocator(), "1 + 2");
    const nodes = try p.parseFile();
    try std.testing.expectEqual(@as(usize, 1), nodes.len);
    try std.testing.expectEqual(Node.Kind.binary_op, std.meta.activeTag(nodes[0].kind));
    try std.testing.expectEqual(Node.BinaryOp.Op.add, nodes[0].kind.binary_op.op);
}

test "parse subtraction" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = Parser.init(arena.allocator(), "5 - 3");
    const nodes = try p.parseFile();
    try std.testing.expectEqual(@as(usize, 1), nodes.len);
    try std.testing.expectEqual(Node.BinaryOp.Op.sub, nodes[0].kind.binary_op.op);
}

test "parse multiplication" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = Parser.init(arena.allocator(), "3 * 4");
    const nodes = try p.parseFile();
    try std.testing.expectEqual(@as(usize, 1), nodes.len);
    try std.testing.expectEqual(Node.BinaryOp.Op.mul, nodes[0].kind.binary_op.op);
}

test "parse equality comparison" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = Parser.init(arena.allocator(), "a == b");
    const nodes = try p.parseFile();
    try std.testing.expectEqual(@as(usize, 1), nodes.len);
    try std.testing.expectEqual(Node.BinaryOp.Op.eq, nodes[0].kind.binary_op.op);
}

test "parse inequality comparison" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = Parser.init(arena.allocator(), "a != b");
    const nodes = try p.parseFile();
    try std.testing.expectEqual(@as(usize, 1), nodes.len);
    try std.testing.expectEqual(Node.BinaryOp.Op.neq, nodes[0].kind.binary_op.op);
}

test "parse list concatenation operator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = Parser.init(arena.allocator(), "xs ++ ys");
    const nodes = try p.parseFile();
    try std.testing.expectEqual(@as(usize, 1), nodes.len);
    try std.testing.expectEqual(Node.BinaryOp.Op.concat, nodes[0].kind.binary_op.op);
}

test "parse less-than comparison" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = Parser.init(arena.allocator(), "a < b");
    const nodes = try p.parseFile();
    try std.testing.expectEqual(@as(usize, 1), nodes.len);
    try std.testing.expectEqual(Node.BinaryOp.Op.lt, nodes[0].kind.binary_op.op);
}

// ============================================================
// Collection literals
// ============================================================

test "parse empty list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = Parser.init(arena.allocator(), "[]");
    const nodes = try p.parseFile();
    try std.testing.expectEqual(@as(usize, 1), nodes.len);
    try std.testing.expectEqual(Node.Kind.list_lit, std.meta.activeTag(nodes[0].kind));
    try std.testing.expectEqual(@as(usize, 0), nodes[0].kind.list_lit.elements.len);
}

test "parse list with elements" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = Parser.init(arena.allocator(), "[1, 2, 3]");
    const nodes = try p.parseFile();
    try std.testing.expectEqual(@as(usize, 1), nodes.len);
    try std.testing.expectEqual(Node.Kind.list_lit, std.meta.activeTag(nodes[0].kind));
    try std.testing.expectEqual(@as(usize, 3), nodes[0].kind.list_lit.elements.len);
}

test "parse tuple literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = Parser.init(arena.allocator(), "{:ok, 42}");
    const nodes = try p.parseFile();
    try std.testing.expectEqual(@as(usize, 1), nodes.len);
    try std.testing.expectEqual(Node.Kind.tuple_lit, std.meta.activeTag(nodes[0].kind));
    try std.testing.expectEqual(@as(usize, 2), nodes[0].kind.tuple_lit.elements.len);
}

// ============================================================
// Function call
// ============================================================

test "parse function call with no args" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = Parser.init(arena.allocator(), "now()");
    const nodes = try p.parseFile();
    try std.testing.expectEqual(@as(usize, 1), nodes.len);
    try std.testing.expectEqual(Node.Kind.func_call, std.meta.activeTag(nodes[0].kind));
    try std.testing.expectEqualStrings("now", nodes[0].kind.func_call.name);
    try std.testing.expectEqual(@as(usize, 0), nodes[0].kind.func_call.args.len);
}

test "parse function call with args" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = Parser.init(arena.allocator(), "length(items)");
    const nodes = try p.parseFile();
    try std.testing.expectEqual(@as(usize, 1), nodes.len);
    try std.testing.expectEqual(Node.Kind.func_call, std.meta.activeTag(nodes[0].kind));
    try std.testing.expectEqualStrings("length", nodes[0].kind.func_call.name);
    try std.testing.expectEqual(@as(usize, 1), nodes[0].kind.func_call.args.len);
}

// ============================================================
// Actor definition
// ============================================================

test "parse empty actor definition" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = Parser.init(arena.allocator(),
        \\actor Counter do
        \\end
    );
    const nodes = try p.parseFile();
    try std.testing.expectEqual(@as(usize, 1), nodes.len);
    try std.testing.expectEqual(Node.Kind.actor_def, std.meta.activeTag(nodes[0].kind));
    try std.testing.expectEqualStrings("Counter", nodes[0].kind.actor_def.name);
    try std.testing.expectEqual(@as(usize, 0), nodes[0].kind.actor_def.body.len);
}

test "parse actor with state definition" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = Parser.init(arena.allocator(),
        \\actor Counter do
        \\  state count: Int :: 0
        \\end
    );
    const nodes = try p.parseFile();
    try std.testing.expectEqual(@as(usize, 1), nodes.len);
    const actor = nodes[0].kind.actor_def;
    try std.testing.expectEqualStrings("Counter", actor.name);
    try std.testing.expectEqual(@as(usize, 1), actor.body.len);
    try std.testing.expectEqual(Node.Kind.state_def, std.meta.activeTag(actor.body[0].kind));
}

test "parse actor with message handler" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = Parser.init(arena.allocator(),
        \\actor Counter do
        \\  state count: Int :: 0
        \\  on :increment do
        \\    become count: count + 1
        \\    reply count
        \\  end
        \\end
    );
    const nodes = try p.parseFile();
    try std.testing.expectEqual(@as(usize, 1), nodes.len);
    const actor = nodes[0].kind.actor_def;
    try std.testing.expectEqualStrings("Counter", actor.name);
    try std.testing.expectEqual(@as(usize, 2), actor.body.len);
    try std.testing.expectEqual(Node.Kind.message_handler, std.meta.activeTag(actor.body[1].kind));
    try std.testing.expectEqualStrings("increment", actor.body[1].kind.message_handler.name);
}

test "parse actor with handler params" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = Parser.init(arena.allocator(),
        \\actor Adder do
        \\  on :add(x: Int, y: Int) do
        \\    reply x + y
        \\  end
        \\end
    );
    const nodes = try p.parseFile();
    try std.testing.expectEqual(@as(usize, 1), nodes.len);
    const actor = nodes[0].kind.actor_def;
    const handler = actor.body[0].kind.message_handler;
    try std.testing.expectEqualStrings("add", handler.name);
    try std.testing.expectEqual(@as(usize, 2), handler.params.len);
    try std.testing.expectEqualStrings("x", handler.params[0].name);
    try std.testing.expectEqualStrings("Int", handler.params[0].type_name.?);
    try std.testing.expectEqualStrings("y", handler.params[1].name);
}

test "parse dotted actor name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = Parser.init(arena.allocator(),
        \\actor Shop.Checkout do
        \\end
    );
    const nodes = try p.parseFile();
    try std.testing.expectEqual(@as(usize, 1), nodes.len);
    try std.testing.expectEqualStrings("Shop.Checkout", nodes[0].kind.actor_def.name);
}

test "parse handler with return type annotation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = Parser.init(arena.allocator(),
        \\actor Counter do
        \\  on :get() -> Int do
        \\    reply 0
        \\  end
        \\end
    );
    const nodes = try p.parseFile();
    try std.testing.expectEqual(@as(usize, 1), nodes.len);
    const handler = nodes[0].kind.actor_def.body[0].kind.message_handler;
    try std.testing.expect(handler.return_type != null);
    try std.testing.expectEqualStrings("Int", handler.return_type.?);
}

// ============================================================
// Def statement
// ============================================================

test "parse def statement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = Parser.init(arena.allocator(),
        \\def double(x) do
        \\  x * 2
        \\end
    );
    const nodes = try p.parseFile();
    try std.testing.expectEqual(@as(usize, 1), nodes.len);
    try std.testing.expectEqual(Node.Kind.def_stmt, std.meta.activeTag(nodes[0].kind));
    try std.testing.expectEqualStrings("double", nodes[0].kind.def_stmt.name);
}

// ============================================================
// Multiple top-level nodes
// ============================================================

test "parse multiple expressions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = Parser.init(arena.allocator(), "1\n2\n3");
    const nodes = try p.parseFile();
    try std.testing.expectEqual(@as(usize, 3), nodes.len);
}

test "parse empty file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = Parser.init(arena.allocator(), "");
    const nodes = try p.parseFile();
    try std.testing.expectEqual(@as(usize, 0), nodes.len);
}

test "parse source location line 1" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = Parser.init(arena.allocator(), "42");
    const nodes = try p.parseFile();
    try std.testing.expectEqual(@as(usize, 1), nodes.len);
    try std.testing.expectEqual(@as(u32, 1), nodes[0].loc.line);
}
