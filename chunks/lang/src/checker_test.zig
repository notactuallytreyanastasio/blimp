/// Tests for checker.zig
/// Run by `zig build test`, through the import in lib.zig's test block.
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

test "a Tuple annotation accepts a tuple" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var p = Parser.init(alloc,
        \\actor A do
        \\  on :m(o: Tuple) -> Tuple do reply o end
        \\end
        \\a = spawn A
        \\r = a <- :m({1, 2})
    );
    const nodes = try p.parseFile();
    var c = Checker.init(alloc);
    const errs = c.checkFile(nodes).errors;
    try std.testing.expectEqual(@as(usize, 0), errs.len);
}

test "an operand already reported as wrong is not reported again by its parent" {
    const sources = [_][]const u8{
        "x = 1 + :a > 0",
        "x = (1 + :a) && true",
        "x = !(1 + :a)",
        "x = -(1 + :a)",
        "x = (1 + :a) + 1",
        "x = length(1 + :a)",
        "x = max(1 + :a, 2)",
    };
    for (sources) |src| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        var p = Parser.init(alloc, src);
        const nodes = try p.parseFile();
        var c = Checker.init(alloc);
        const errs = c.checkFile(nodes).errors;
        if (errs.len != 1) {
            for (errs) |e| std.debug.print("{s}: {s}\n", .{ src, e.message });
        }
        try std.testing.expectEqual(@as(usize, 1), errs.len);
        try std.testing.expect(std.mem.indexOf(u8, errs[0].message, "arithmetic on incompatible types") != null);
    }
}

// ============================================================
// Every body and expression position is checked
// ============================================================

fn checkSource(alloc: std.mem.Allocator, source: []const u8) ![]const checker_mod.TypeError {
    var p = Parser.init(alloc, source);
    const nodes = try p.parseFile();
    var c = Checker.init(alloc);
    return c.checkFile(nodes).errors;
}

/// One error, containing `want`, on line `line`.
fn expectOneError(source: []const u8, want: []const u8, line: usize) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const errs = try checkSource(arena.allocator(), source);
    if (errs.len != 1) {
        for (errs) |e| std.debug.print("  line {d}: {s}\n", .{ e.loc.line, e.message });
        std.debug.print("expected 1 error for:\n{s}\ngot {d}\n", .{ source, errs.len });
        return error.TestUnexpectedResult;
    }
    try std.testing.expect(std.mem.indexOf(u8, errs[0].message, want) != null);
    try std.testing.expectEqual(line, errs[0].loc.line);
}

fn expectNoErrors(source: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const errs = try checkSource(arena.allocator(), source);
    for (errs) |e| std.debug.print("  line {d}: {s}\n", .{ e.loc.line, e.message });
    try std.testing.expectEqual(@as(usize, 0), errs.len);
}

const bad = "arithmetic on incompatible types";

test "checker looks inside a case: scrutinee, guard, branch body, case as a value" {
    try expectOneError("case 1 + :a do\n  _ -> 0\nend", bad, 1);
    try expectOneError("case 1 do\n  n when 1 + :a > 0 -> 0\n  _ -> 0\nend", bad, 2);
    try expectOneError("case 1 do\n  1 -> x = 1 + :a\n  _ -> 0\nend", bad, 2);
    try expectOneError("y = case 1 do\n  _ -> 1 + :a\nend", bad, 2);
}

test "checker looks inside a situation" {
    try expectOneError("situation 1 + :a do\n  _ -> 0\nend", bad, 1);
    try expectOneError("situation 1 do\n  1 -> x = 1 + :a\n  _ -> 0\nend", bad, 2);
}

test "checker looks inside test and property bodies" {
    try expectOneError("actor T do\n  test \"t\" do\n    x = 1 + :a\n  end\nend", bad, 3);
    try expectOneError(
        \\actor A do
        \\  on :add(k: Int) -> Int do reply k end
        \\end
        \\actor T do
        \\  state c: A :: spawn A
        \\  test "t" do
        \\    r = c <- :add("x")
        \\  end
        \\end
    , "argument 1 to :add expected Int, got String", 7);
    try expectOneError("actor T do\n  property \"p\" do\n    given a: gen_integer(0, 1)\n    x = 1 + :a\n  end\nend", bad, 4);
    try expectOneError("actor T do\n  property \"p\" do\n    given a: gen_integer(0, 1 + :a)\n    assert(true)\n  end\nend", bad, 3);
}

test "checker looks inside fn, for, try and catch bodies" {
    try expectOneError("f = fn(y: Int) do\n  x = 1 + :a\n  y\nend", bad, 2);
    try expectOneError("y = map([1], fn(i: Int) do i + :a end)", bad, 1);
    try expectOneError("for i in 1 + :a do i end", bad, 1);
    try expectOneError("for i in [1] do\n  x = 1 + :a\nend", bad, 2);
    try expectOneError("try do\n  x = 1 + :a\ncatch e do\n  0\nend", bad, 2);
    try expectOneError("try do\n  0\ncatch e do\n  x = 1 + :a\nend", bad, 4);
}

test "checker looks at every element, the orelse fallback, overrides and interpolations" {
    try expectOneError("1 + :a", bad, 1);
    try expectOneError("y = [1, 1 + :a]", bad, 1);
    try expectOneError("y = [1 | 1 + :a]", bad, 1);
    try expectOneError("y = %{a: 1, b: 1 + :a}", bad, 1);
    try expectOneError("y = nil orelse 1 + :a", bad, 1);
    try expectOneError("actor A do\n  state n: Int :: 0\nend\ny = spawn A, n: 1 + :a", bad, 4);
    try expectOneError("actor A do\n  state n: Int :: 0\nend\ny = %A{n: 1 + :a}", bad, 4);
    try expectOneError("actor A do\n  on :m do bubble 1 + :a end\nend", bad, 2);
    try expectOneError("actor A do\n  on :m(k: Int) when k + :a > 0 do reply k end\nend", bad, 2);
    try expectOneError("y = ...[1], fn(i: Int) do i + :a end", bad, 1);
}

test "an error inside #{} is reported at the string, not at line 1" {
    try expectOneError("z = 1\n\ny = \"v #{1 + :a}\"", bad, 3);
}

test "a reply inside a case branch is held to the handler's return type" {
    try expectOneError("actor A do\n  on :m -> Int do\n    case 1 do\n      _ -> reply :a\n    end\n  end\nend", "reply type mismatch: expected Int, got Atom", 4);
}

test "a pattern name shadows an outer variable of the same name" {
    // n is an Int outside; inside the branch it is whatever matched.
    try expectNoErrors(
        \\actor A do
        \\  state n: Int :: 0
        \\  on :m(msg: Any) do
        \\    case msg do
        \\      {:name, n} -> x = n ++ "!"
        \\      _ -> 0
        \\    end
        \\  end
        \\end
    );
}

// Which nested bodies' assignments are seen afterwards, as the
// interpreter runs them: a for body, a catch body and a case branch other
// than `_ ->` have a scope of their own; a try body and a `_ ->` branch
// run in the enclosing one.

test "an assignment in a for body leaves the outer type alone" {
    // Both stop with TYPE MISMATCH at run time: the outer x is unchanged.
    try expectOneError("x = nil\nfor i in [1, 2] do\n  x = i\nend\ny = x + 1", bad, 5);
    try expectOneError("x = 1\nfor i in [1] do\n  x = 2\nend\ny = x + :a", bad, 5);
}

test "an assignment in a case branch other than _ leaves the outer type alone" {
    try expectOneError("x = :none\ncase 1 do\n  1 -> x = 2\n  _ -> 0\nend\ny = x + 1", bad, 6);
    try expectOneError("x = :none\ncase true do\n  true -> x = 2\n  false -> 0\nend\ny = x + 1", bad, 6);
    try expectNoErrors("x = 1\nsituation 1 do\n  1 -> x = :a\n  _ -> 0\nend\ny = x + 1");
}

test "an assignment in a catch body leaves the outer type alone" {
    try expectOneError("x = :none\ntry do\n  0\ncatch e do\n  x = 2\nend\ny = x + 1", bad, 7);
}

test "an assignment in a try body is seen after it" {
    try expectNoErrors("x = :none\ntry do\n  x = 2\ncatch e do\n  0\nend\ny = x + 1");
    try expectOneError("x = 1\ntry do\n  x = :a\ncatch e do\n  0\nend\ny = x + 1", bad, 7);
}

test "a first _ branch always runs, and its assignment is seen after the case" {
    try expectNoErrors("x = :none\ncase 1 do\n  _ -> x = 2\nend\ny = x + 1");
    try expectOneError("x = 1\ncase 1 do\n  _ -> x = :a\nend\ny = x + 1", bad, 5);
}

test "a later _ branch that changes an outer name's type is reported" {
    try expectOneError("x = 1\ncase 2 do\n  1 -> 0\n  _ -> x = :a\nend", "only a `_ ->` branch's assignment is seen after the case", 4);
    try expectOneError("x = 1\nsituation 2 do\n  1 -> 0\n  _ -> x = :a\nend", "only a `_ ->` branch's assignment is seen after the case", 4);
    // Same type, or a name the outer scope does not have: nothing to say.
    try expectNoErrors("x = 1\ncase 2 do\n  1 -> 0\n  _ -> x = 5\nend\ny = x + 1");
    try expectNoErrors("case 2 do\n  1 -> 0\n  _ -> z = :a\nend");
    // A name only a later `_ ->` binds is known afterwards with its type.
    try expectOneError("case 2 do\n  1 -> 0\n  _ -> z = :a\nend\ny = z + 1", bad, 5);
    try expectNoErrors("case 2 do\n  1 -> 0\n  _ -> z = 5\nend\ny = z + 1");
    // Inside a for body the branch's assignment escapes only into the
    // for body's scope, which does not escape.
    try expectNoErrors("x = 1\nfor i in [1] do\n  case 2 do\n    _ -> x = :a\n  end\nend\ny = x + 1");
}

test "a reply in a def or fn inside a handler is not the handler's" {
    try expectNoErrors(
        \\actor A do
        \\  on :m -> Int do
        \\    f = fn(s: String) do s end
        \\    reply 1
        \\  end
        \\end
    );
}

test "a Tuple annotation inside a lambda compares with a tuple" {
    try expectNoErrors("f = fn(o: Tuple) do o == {1, 2} end");
}

test "the later _ branch message is whole" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const errs = try checkSource(arena.allocator(), "x = 1\ncase 2 do\n  1 -> 0\n  _ -> x = :a\nend");
    try std.testing.expectEqual(@as(usize, 1), errs.len);
    try std.testing.expectEqualStrings(
        "'x' is Int before this case and the `_ ->` branch makes it Atom; only a `_ ->` branch's assignment is seen after the case, so after it 'x' is Int or Atom depending on which branch ran",
        errs[0].message,
    );
}
