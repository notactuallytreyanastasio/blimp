/// Tests for checker.zig - run with: zig test src/checker_test.zig --main-mod-path src
const std = @import("std");
const checker_mod = @import("checker.zig");
const Checker = checker_mod.Checker;
const ActorRegistry = checker_mod.ActorRegistry;
const ActorInfo = checker_mod.ActorInfo;
const Parser = @import("parser.zig").Parser;

// ============================================================
// ActorRegistry
// ============================================================

test "ActorRegistry register and lookup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var reg = ActorRegistry.init(arena.allocator());

    _ = reg.register("Counter");
    const info = reg.lookupActor("Counter");
    try std.testing.expect(info != null);
}

test "ActorRegistry lookup missing returns null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var reg = ActorRegistry.init(arena.allocator());

    const info = reg.lookupActor("Nonexistent");
    try std.testing.expect(info == null);
}

test "ActorRegistry register same name returns same info" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var reg = ActorRegistry.init(arena.allocator());

    const a = reg.register("Counter");
    const b = reg.register("Counter");
    // Both pointers should refer to the same actor entry
    try std.testing.expectEqual(a, b);
}

test "ActorRegistry multiple actors are independent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var reg = ActorRegistry.init(arena.allocator());

    _ = reg.register("Counter");
    _ = reg.register("Timer");

    try std.testing.expect(reg.lookupActor("Counter") != null);
    try std.testing.expect(reg.lookupActor("Timer") != null);
    try std.testing.expect(reg.lookupActor("Other") == null);
}

// ============================================================
// ActorInfo state field and handler lookups
// ============================================================

test "ActorInfo lookupStateField missing returns null" {
    var info = ActorInfo.init();
    const result = info.lookupStateField("count");
    try std.testing.expect(result == null);
}

test "ActorInfo lookupHandler missing returns null" {
    var info = ActorInfo.init();
    const result = info.lookupHandler("increment");
    try std.testing.expect(result == null);
}

// ============================================================
// Checker.checkFile
// ============================================================

test "checkFile empty file returns no errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var p = Parser.init(alloc, "");
    const nodes = try p.parseFile();

    var c = Checker.init(alloc);
    const result = c.checkFile(nodes);
    try std.testing.expectEqual(@as(usize, 0), result.errors.len);
}

test "checkFile simple expression has no type errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var p = Parser.init(alloc, "42");
    const nodes = try p.parseFile();

    var c = Checker.init(alloc);
    const result = c.checkFile(nodes);
    try std.testing.expectEqual(@as(usize, 0), result.errors.len);
}

test "checkFile actor registers in registry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var p = Parser.init(alloc,
        \\actor Counter do
        \\  state count: Int :: 0
        \\end
    );
    const nodes = try p.parseFile();

    var c = Checker.init(alloc);
    _ = c.checkFile(nodes);

    const info = c.registry.lookupActor("Counter");
    try std.testing.expect(info != null);
}

test "checkFile actor state fields are registered with types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var p = Parser.init(alloc,
        \\actor Counter do
        \\  state count: Int :: 0
        \\end
    );
    const nodes = try p.parseFile();

    var c = Checker.init(alloc);
    _ = c.checkFile(nodes);

    const info = c.registry.lookupActor("Counter").?;
    const ty = info.lookupStateField("count");
    try std.testing.expect(ty != null);
}

test "checkFile actor handler signature is registered" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var p = Parser.init(alloc,
        \\actor Counter do
        \\  state count: Int :: 0
        \\  on :increment do
        \\    become count: count + 1
        \\    reply count
        \\  end
        \\end
    );
    const nodes = try p.parseFile();

    var c = Checker.init(alloc);
    _ = c.checkFile(nodes);

    const info = c.registry.lookupActor("Counter").?;
    const sig = info.lookupHandler("increment");
    try std.testing.expect(sig != null);
}

test "checkFile two actors are independently registered" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var p = Parser.init(alloc,
        \\actor Foo do
        \\  state x: Int :: 0
        \\end
        \\actor Bar do
        \\  state y: String :: ""
        \\end
    );
    const nodes = try p.parseFile();

    var c = Checker.init(alloc);
    _ = c.checkFile(nodes);

    try std.testing.expect(c.registry.lookupActor("Foo") != null);
    try std.testing.expect(c.registry.lookupActor("Bar") != null);
    try std.testing.expect(c.registry.lookupActor("Baz") == null);
}

test "checkFile handler with typed params registers param types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var p = Parser.init(alloc,
        \\actor Adder do
        \\  on :add(x: Int, y: Int) do
        \\    reply x + y
        \\  end
        \\end
    );
    const nodes = try p.parseFile();

    var c = Checker.init(alloc);
    _ = c.checkFile(nodes);

    const info = c.registry.lookupActor("Adder").?;
    const sig = info.lookupHandler("add").?;
    try std.testing.expectEqual(@as(usize, 2), sig.param_names.len);
    try std.testing.expectEqualStrings("x", sig.param_names[0]);
    try std.testing.expectEqualStrings("y", sig.param_names[1]);
}
