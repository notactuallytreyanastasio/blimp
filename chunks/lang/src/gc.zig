//! Copying collection for the evaluator heap.
//!
//! The tree-walking evaluator never frees anything: every value, closure
//! capture and scope binding stays alive for the life of the allocator it
//! was created in.  That is fine for a one-shot native run (an arena freed
//! at exit) but a browser session evaluates thousands of small programs
//! against the same evaluator, so the WASM host needs a way to drop the
//! garbage between evals.
//!
//! `compact` copies everything the evaluator can still reach (the global
//! environment, the actor registry with each instance's state and mailbox,
//! and a few evaluator fields) into a fresh allocator and points the
//! evaluator at it.  The caller then frees the old allocator.  Values are
//! immutable and closures capture flat binding lists, so a deep copy with a
//! pointer memo preserves sharing and terminates on cycles.  AST nodes and
//! source text are not copied: closures and handlers keep pointing at them,
//! so those must live in an allocator that outlives every compaction.
//!
//! Only call this between evals.  Nothing on the Zig stack may hold a value
//! pointer (no active handler, no actor context) when it runs.

const std = @import("std");
const Value = @import("value.zig").Value;
const Evaluator = @import("eval.zig").Evaluator;
const Environment = @import("env.zig").Environment;
const registry_mod = @import("registry.zig");
const Registry = registry_mod.Registry;
const mailbox_mod = @import("mailbox.zig");
const Mailbox = mailbox_mod.Mailbox;
const Message = mailbox_mod.Message;
const BuiltinRegistry = @import("builtins.zig").BuiltinRegistry;

pub const CompactError = error{OutOfMemory};

/// Copy the evaluator's live data into `to` and make `to` its allocator.
/// `scratch` holds the pointer memo for the duration of the call and is
/// left clean.  On error the evaluator is untouched (everything already
/// copied into `to` is simply abandoned there).
pub fn compact(eval: *Evaluator, to: std.mem.Allocator, scratch: std.mem.Allocator) CompactError!void {
    _ = try compactWith(eval, to, scratch, .keep_all);
}

/// What a compaction does with actors nothing can reach.
pub const Actors = enum {
    /// Copy every instance, reachable or not. The REPL and the browser keep
    /// this: a host (blimp.js) may hold an actor's id where no Blimp value
    /// does, so "unreachable from Blimp" does not mean unreachable.
    keep_all,
    /// Copy only the instances a live value can still name, and those with
    /// work pending. `blimp --serve` uses this: its only host is the tick,
    /// and every actor a program means to keep is bound somewhere.
    drop_unreachable,
};

/// The same, and the number of actor instances left behind.
///
/// An actor instance is kept when:
///   - some value copied from a root (the top-level scope, the templates'
///     defaults, the pending bubble) or from a kept actor's state or mailbox
///     holds its ref, or
///   - it has messages waiting, is not idle, or is on the scheduler's run
///     queue: it has work to do whether or not anyone holds it.
/// Everything else can never receive another message, so it is dropped with
/// the rest of the garbage. Ids are never reused (`next_id` only grows), so
/// a ref printed before the drop still names nothing rather than someone
/// else.
pub fn compactWith(eval: *Evaluator, to: std.mem.Allocator, scratch: std.mem.Allocator, actors: Actors) CompactError!usize {
    var copier = Copier{
        .to = to,
        .values = std.AutoHashMap(usize, *const Value).init(scratch),
        .handlers = std.AutoHashMap(usize, []const Value.HandlerDef).init(scratch),
        .seen = std.AutoHashMap(u64, void).init(scratch),
        .pending = .{ .items = &.{}, .capacity = 0 },
        .scratch = scratch,
    };
    defer copier.values.deinit();
    defer copier.handlers.deinit();
    defer copier.seen.deinit();
    defer copier.pending.deinit(scratch);

    // Build every replacement first, then swap them in, so a failure
    // part-way leaves the evaluator consistent.
    const scopes = try copier.scopes(eval.env.scopes.items);
    const templates = try copier.templates(eval.registry.templates.items);
    const bubble_reason: ?*const Value = if (eval.bubble_reason) |r| try copier.value(r) else null;
    if (eval.scheduler) |sched| {
        for (sched.run_queue.items) |id| try copier.see(id);
    }
    const old_instances = eval.registry.instances.items;
    const instances = switch (actors) {
        .keep_all => try copier.instances(old_instances),
        .drop_unreachable => try copier.reachableInstances(old_instances),
    };
    const dropped = old_instances.len - instances.items.len;
    // One slot per entry the evaluator can hold.  The WASM host drains the
    // log after every eval so 64 was enough there; a REPL that never reads it
    // fills all 256 and used to walk off the end of this buffer.
    var msg_log: [Evaluator.msg_log_cap]Evaluator.MsgLogEntry = undefined;
    for (0..eval.msg_log_count) |i| {
        const e = eval.msg_log[i];
        msg_log[i] = .{
            .target_id = e.target_id,
            .target_type = try copier.str(e.target_type),
            .message = try copier.str(e.message),
        };
    }

    eval.env.scopes = scopes;
    // The recycled binding lists belong to the allocator being dropped.
    eval.env.free_scopes = .{ .items = &.{}, .capacity = 0 };
    eval.env.allocator = to;
    eval.env.reindexGlobals();
    eval.registry.templates = templates;
    eval.registry.instances = instances;
    eval.registry.allocator = to;
    eval.bubble_reason = bubble_reason;
    for (0..eval.msg_log_count) |i| eval.msg_log[i] = msg_log[i];
    eval.builtins = BuiltinRegistry.init(to);
    eval.allocator = to;
    return dropped;
}

const Copier = struct {
    to: std.mem.Allocator,
    values: std.AutoHashMap(usize, *const Value),
    handlers: std.AutoHashMap(usize, []const Value.HandlerDef),
    /// Every actor id a copied value holds, and those not yet visited.
    seen: std.AutoHashMap(u64, void),
    pending: std.ArrayList(u64),
    scratch: std.mem.Allocator,

    fn see(self: *Copier, id: u64) CompactError!void {
        const got = try self.seen.getOrPut(id);
        if (!got.found_existing) try self.pending.append(self.scratch, id);
    }

    fn str(self: *Copier, s: []const u8) CompactError![]const u8 {
        return self.to.dupe(u8, s);
    }

    fn optStr(self: *Copier, s: ?[]const u8) CompactError!?[]const u8 {
        return if (s) |x| try self.str(x) else null;
    }

    fn value(self: *Copier, v: *const Value) CompactError!*const Value {
        if (self.values.get(@intFromPtr(v))) |done| return done;
        const nv = try self.to.create(Value);
        // Register before recursing so shared and cyclic references resolve
        // to this copy.
        try self.values.put(@intFromPtr(v), nv);
        nv.* = switch (v.*) {
            .integer, .float, .boolean, .nil, .hole => v.*,
            .string => |s| .{ .string = try self.str(s) },
            .atom => |a| .{ .atom = try self.str(a) },
            .list => |items| .{ .list = try self.valueList(items) },
            .tuple => |items| .{ .tuple = try self.valueList(items) },
            .map => |entries| .{ .map = try self.mapEntries(entries) },
            .actor_ref => |r| blk: {
                try self.see(r.id);
                break :blk .{ .actor_ref = .{ .id = r.id, .type_name = try self.str(r.type_name) } };
            },
            .closure => |c| .{ .closure = try self.closure(c) },
            .view_node => |n| .{ .view_node = try self.viewNode(n) },
        };
        return nv;
    }

    fn viewNode(self: *Copier, n: *const Value.ViewNode) CompactError!*const Value.ViewNode {
        const out = try self.to.create(Value.ViewNode);
        out.* = .{
            .tag = try self.str(n.tag),
            .attrs = try self.attrs(n.attrs),
            .children = try self.valueList(n.children),
        };
        return out;
    }

    fn closure(self: *Copier, c: *const Value.Closure) CompactError!*const Value.Closure {
        const out = try self.to.create(Value.Closure);
        out.* = .{
            .params = c.params,
            .body = c.body,
            .env = try self.captured(c.env),
            // The bitmask lookup checks before it searches env; left at its
            // default of 0 it says the closure captured nothing, and every
            // captured name falls through to whatever the caller has bound.
            .env_names = c.env_names,
            .top_level = c.top_level,
            // The top-level scope is copied whole and in order, so the mark
            // still counts the same bindings.
            .globals_mark = c.globals_mark,
            .return_type = try self.optStr(c.return_type),
        };
        return out;
    }

    fn valueList(self: *Copier, items: []const *const Value) CompactError![]const *const Value {
        const out = try self.to.alloc(*const Value, items.len);
        for (items, 0..) |item, i| out[i] = try self.value(item);
        return out;
    }

    fn mapEntries(self: *Copier, entries: []const Value.MapEntry) CompactError![]Value.MapEntry {
        const out = try self.to.alloc(Value.MapEntry, entries.len);
        for (entries, 0..) |e, i| out[i] = .{ .key = try self.str(e.key), .val = try self.value(e.val) };
        return out;
    }

    fn captured(self: *Copier, bindings: []const Value.CapturedBinding) CompactError![]const Value.CapturedBinding {
        const out = try self.to.alloc(Value.CapturedBinding, bindings.len);
        for (bindings, 0..) |b, i| out[i] = .{ .name = try self.str(b.name), .val = try self.value(b.val) };
        return out;
    }

    fn attrs(self: *Copier, list: []const Value.ViewNode.ViewAttr) CompactError![]const Value.ViewNode.ViewAttr {
        const out = try self.to.alloc(Value.ViewNode.ViewAttr, list.len);
        for (list, 0..) |a, i| out[i] = .{ .key = try self.str(a.key), .val = try self.value(a.val) };
        return out;
    }

    // Handler tables are shared between a template and its instances, so
    // memo them by slice address to keep that sharing.
    fn handlerDefs(self: *Copier, defs: []const Value.HandlerDef) CompactError![]const Value.HandlerDef {
        if (defs.len == 0) return defs;
        if (self.handlers.get(@intFromPtr(defs.ptr))) |done| return done;
        const out = try self.to.alloc(Value.HandlerDef, defs.len);
        for (defs, 0..) |h, i| out[i] = .{
            .name = try self.str(h.name),
            .params = h.params,
            .guard = h.guard,
            .body = h.body,
            .bubble_strategy = try self.optStr(h.bubble_strategy),
        };
        try self.handlers.put(@intFromPtr(defs.ptr), out);
        return out;
    }

    fn scopes(self: *Copier, old: []const Environment.Scope) CompactError!std.ArrayList(Environment.Scope) {
        var out: std.ArrayList(Environment.Scope) = .{ .items = &.{}, .capacity = 0 };
        try out.ensureTotalCapacity(self.to, old.len);
        for (old) |scope| {
            var bindings: std.ArrayList(Environment.Binding) = .{ .items = &.{}, .capacity = 0 };
            try bindings.ensureTotalCapacity(self.to, scope.bindings.items.len);
            // The scope's name mask is rebuilt from what lands here rather
            // than copied: a stale mask hides bindings from every lookup.
            var names: u64 = 0;
            for (scope.bindings.items) |b| {
                const name = try self.str(b.name);
                names |= Environment.nameBit(name);
                bindings.appendAssumeCapacity(.{ .name = name, .val = try self.value(b.val) });
            }
            out.appendAssumeCapacity(.{ .bindings = bindings, .names = names });
        }
        return out;
    }

    fn templates(self: *Copier, old: []const registry_mod.ActorTemplate) CompactError!std.ArrayList(registry_mod.ActorTemplate) {
        var out: std.ArrayList(registry_mod.ActorTemplate) = .{ .items = &.{}, .capacity = 0 };
        try out.ensureTotalCapacity(self.to, old.len);
        for (old) |t| {
            out.appendAssumeCapacity(.{
                .name = try self.str(t.name),
                .default_state = try self.mapEntries(t.default_state),
                .handlers = try self.handlerDefs(t.handlers),
            });
        }
        return out;
    }

    // Entries are boxed so the evaluator's `*ActorEntry` survives a spawn;
    // a compaction moves them to a fresh box in the new heap.  Nothing may
    // be holding one of those pointers when this runs -- see the module
    // comment.
    fn instances(self: *Copier, old: []const *registry_mod.ActorEntry) CompactError!std.ArrayList(*registry_mod.ActorEntry) {
        var out: std.ArrayList(*registry_mod.ActorEntry) = .{ .items = &.{}, .capacity = 0 };
        try out.ensureTotalCapacity(self.to, old.len);
        for (old) |e| out.appendAssumeCapacity(try self.entry(e));
        return out;
    }

    fn entry(self: *Copier, e: *const registry_mod.ActorEntry) CompactError!*registry_mod.ActorEntry {
        const ne = try self.to.create(registry_mod.ActorEntry);
        ne.* = .{
            .ref = .{ .id = e.ref.id, .type_name = try self.str(e.ref.type_name) },
            .state_fields = try self.mapEntries(e.state_fields),
            .handlers = try self.handlerDefs(e.handlers),
            .status = e.status,
            .mailbox = try self.mailbox(e.mailbox),
            .reductions = e.reductions,
        };
        return ne;
    }

    /// The instances something can still reach, in their original order.
    /// A worklist, not repeated passes: copying one actor's state can name
    /// another, and a chain of actors each holding the next (a Temper
    /// ListBuilder's nodes, say) would otherwise take a pass per link.
    fn reachableInstances(self: *Copier, old: []const *registry_mod.ActorEntry) CompactError!std.ArrayList(*registry_mod.ActorEntry) {
        var index = std.AutoHashMap(u64, usize).init(self.scratch);
        defer index.deinit();
        try index.ensureTotalCapacity(@intCast(old.len));
        for (old, 0..) |e, i| index.putAssumeCapacity(e.ref.id, i);

        // Work pending makes an actor a root of its own.
        for (old) |e| {
            if (e.mailbox.messages.items.len > 0 or (e.status != .idle and e.status != .dead)) try self.see(e.ref.id);
        }

        const copies = try self.scratch.alloc(?*registry_mod.ActorEntry, old.len);
        defer self.scratch.free(copies);
        @memset(copies, null);
        while (self.pending.pop()) |id| {
            const i = index.get(id) orelse continue; // a ref to an actor already gone
            if (copies[i] != null) continue;
            copies[i] = try self.entry(old[i]);
        }

        var out: std.ArrayList(*registry_mod.ActorEntry) = .{ .items = &.{}, .capacity = 0 };
        for (copies) |c| if (c) |ne| try out.append(self.to, ne);
        return out;
    }

    fn mailbox(self: *Copier, old: Mailbox) CompactError!Mailbox {
        var out = Mailbox.init();
        try out.messages.ensureTotalCapacity(self.to, old.messages.items.len);
        for (old.messages.items) |m| {
            // Nobody can be blocked on a reply between evals.
            out.messages.appendAssumeCapacity(.{ .name = try self.str(m.name), .args = try self.valueList(m.args), .reply_slot = null });
        }
        return out;
    }
};

// ============================================================
// Tests
// ============================================================

const Parser = @import("parser.zig").Parser;

fn run(code: std.mem.Allocator, eval: *Evaluator, source: []const u8) !*const Value {
    // The AST lives in `code`, which outlives every heap swap.
    var parser = Parser.init(code, source);
    const nodes = try parser.parseFile();
    var last: *const Value = undefined;
    for (nodes) |node| last = try eval.eval(node);
    return last;
}

const program =
    \\actor Counter do
    \\  state count: Int :: 0
    \\  state log: List :: []
    \\  state tags: Map :: %{kind: :counter}
    \\  on :add(n: Int) do
    \\    become count: count + n, log: [n | log]
    \\    reply count + n
    \\  end
    \\  on :count do reply count end
    \\  on :log do reply log end
    \\  on :kind do reply lookup(tags, :kind) end
    \\  on :panel do reply stack(heading("counter"), text("n = #{count}"), button("more", :add)) end
    \\end
    \\def twice(f: Function, x: Int) -> Int do f(f(x)) end
    \\def inc(x: Int) -> Int do x + 1 end
    \\c = spawn Counter
    \\other = spawn Counter, count: 10
    \\shared = [1, 2, 3]
    \\pair = {shared, shared}
    \\greeting = "hello"
    \\c <- :add(5)
;

fn checkProgram(eval: *Evaluator, code: std.mem.Allocator) !void {
    try std.testing.expectEqual(@as(i64, 5), (try run(code, eval, "c <- :count")).integer);
    try std.testing.expectEqual(@as(i64, 10), (try run(code, eval, "other <- :count")).integer);
    try std.testing.expectEqual(@as(i64, 12), (try run(code, eval, "c <- :add(7)")).integer);
    try std.testing.expectEqual(@as(i64, 12), (try run(code, eval, "c <- :count")).integer);
    try std.testing.expectEqual(@as(i64, 7), (try run(code, eval, "head(c <- :log)")).integer);
    try std.testing.expectEqual(@as(i64, 5), (try run(code, eval, "elem(c <- :log, 1)")).integer);
    try std.testing.expectEqualStrings("counter", (try run(code, eval, "c <- :kind")).atom);
    try std.testing.expectEqual(@as(i64, 3), (try run(code, eval, "twice(inc, 1)")).integer);
    try std.testing.expectEqual(@as(i64, 6), (try run(code, eval, "sum(shared)")).integer);
    try std.testing.expect((try run(code, eval, "pair")).eql((try run(code, eval, "{[1, 2, 3], [1, 2, 3]}")).*));
    try std.testing.expectEqualStrings("hello", (try run(code, eval, "greeting")).string);
    const panel = try run(code, eval, "c <- :panel");
    try std.testing.expect(panel.* == .view_node);
    try std.testing.expectEqual(@as(usize, 3), panel.view_node.children.len);
    // become after compaction still lands in the registry
    _ = try run(code, eval, "c <- :add(-12)");
    try std.testing.expectEqual(@as(i64, 0), (try run(code, eval, "c <- :count")).integer);
    _ = try run(code, eval, "c <- :add(5)");
}

test "compact keeps actors, closures, bindings and views alive after the old heap is freed" {
    var code = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer code.deinit();
    var heap_a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer heap_a.deinit();
    var heap_b = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer heap_b.deinit();

    var eval = Evaluator.init(heap_a.allocator());
    _ = try run(code.allocator(), &eval, program);
    try checkProgram(&eval, code.allocator());

    try compact(&eval, heap_b.allocator(), std.testing.allocator);
    _ = heap_a.reset(.free_all);

    try checkProgram(&eval, code.allocator());
}

test "compact can run after every eval, swapping heaps back and forth" {
    var code = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer code.deinit();
    var heaps = [2]std.heap.ArenaAllocator{
        std.heap.ArenaAllocator.init(std.testing.allocator),
        std.heap.ArenaAllocator.init(std.testing.allocator),
    };
    defer heaps[0].deinit();
    defer heaps[1].deinit();
    var live: usize = 0;

    var eval = Evaluator.init(heaps[live].allocator());
    _ = try run(code.allocator(), &eval, program);

    var i: i64 = 0;
    while (i < 20) : (i += 1) {
        _ = try run(code.allocator(), &eval, "c <- :add(1)");
        const next = 1 - live;
        try compact(&eval, heaps[next].allocator(), std.testing.allocator);
        _ = heaps[live].reset(.free_all);
        live = next;
        try std.testing.expectEqual(5 + i + 1, (try run(code.allocator(), &eval, "c <- :count")).integer);
    }
    try std.testing.expectEqual(@as(usize, 20 + 1), (try run(code.allocator(), &eval, "c <- :log")).list.len);
    try std.testing.expectEqual(@as(i64, 3), (try run(code.allocator(), &eval, "twice(inc, 1)")).integer);
}

test "compact preserves sharing between references to one value" {
    var code = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer code.deinit();
    var heap_a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer heap_a.deinit();
    var heap_b = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer heap_b.deinit();

    var eval = Evaluator.init(heap_a.allocator());
    _ = try run(code.allocator(), &eval, program);
    try compact(&eval, heap_b.allocator(), std.testing.allocator);
    _ = heap_a.reset(.free_all);

    const pair = try run(code.allocator(), &eval, "pair");
    try std.testing.expect(pair.tuple[0] == pair.tuple[1]);
}

test "compact copies a full message log" {
    var code = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer code.deinit();
    var heap_a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer heap_a.deinit();
    var heap_b = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer heap_b.deinit();

    var eval = Evaluator.init(heap_a.allocator());
    _ = try run(code.allocator(), &eval, program);

    // Nothing reads the log in a REPL session, so it fills to its cap.
    while (eval.msg_log_count < Evaluator.msg_log_cap) {
        _ = try run(code.allocator(), &eval, "c <- :count");
    }

    try compact(&eval, heap_b.allocator(), std.testing.allocator);
    _ = heap_a.reset(.free_all);

    try std.testing.expectEqual(@as(i64, 5), (try run(code.allocator(), &eval, "c <- :count")).integer);
}

test "an actor defined by blimp_eval survives compaction" {
    var code = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer code.deinit();
    var heaps = [2]std.heap.ArenaAllocator{
        std.heap.ArenaAllocator.init(std.testing.allocator),
        std.heap.ArenaAllocator.init(std.testing.allocator),
    };
    defer heaps[0].deinit();
    defer heaps[1].deinit();
    var live: usize = 0;

    var eval = Evaluator.init(heaps[live].allocator());
    eval.code_allocator = code.allocator();
    _ = try run(code.allocator(), &eval,
        \\blimp_eval("actor Hot do\n  on :hi(who: String) do\n    reply concat(\"yo \", who)\n  end\nend")
        \\h = spawn Hot
    );

    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const next = 1 - live;
        try compact(&eval, heaps[next].allocator(), std.testing.allocator);
        // free_all hands the pages back; the testing allocator poisons them,
        // so a handler still pointing into the old heap reads garbage
        _ = heaps[live].reset(.free_all);
        live = next;
        try std.testing.expectEqualStrings("yo there", (try run(code.allocator(), &eval, "h <- :hi(\"there\")")).string);
    }
}

test "a top-level def sees the current definition of the defs it calls" {
    var code = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer code.deinit();
    var heaps = [2]std.heap.ArenaAllocator{
        std.heap.ArenaAllocator.init(std.testing.allocator),
        std.heap.ArenaAllocator.init(std.testing.allocator),
    };
    defer heaps[0].deinit();
    defer heaps[1].deinit();

    var eval = Evaluator.init(heaps[0].allocator());
    eval.code_allocator = code.allocator();
    _ = try run(code.allocator(), &eval,
        \\def greet(who: String) -> String do concat("hello ", who) end
        \\def page(who: String) -> String do concat("<p>", greet(who), "</p>") end
        \\def loop(n: Int, acc: String) -> String do
        \\  case n do
        \\    0 -> acc
        \\    _ -> loop(n - 1, concat(acc, greet("x")))
        \\  end
        \\end
    );
    try std.testing.expectEqualStrings("<p>hello b</p>", (try run(code.allocator(), &eval, "page(\"b\")")).string);

    // redefined the way the control socket does it: another top-level def
    _ = try run(code.allocator(), &eval, "def greet(who: String) -> String do concat(\"howdy \", who) end");
    try compact(&eval, heaps[1].allocator(), std.testing.allocator);
    _ = heaps[0].reset(.free_all);

    try std.testing.expectEqualStrings("<p>howdy b</p>", (try run(code.allocator(), &eval, "page(\"b\")")).string);
    // through a tail call, whose frame is collapsed
    try std.testing.expectEqualStrings("howdy xhowdy x", (try run(code.allocator(), &eval, "loop(2, \"\")")).string);
}

test "a def inside a function still keeps what it captured" {
    var code = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer code.deinit();
    var heap = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer heap.deinit();
    var eval = Evaluator.init(heap.allocator());
    _ = try run(code.allocator(), &eval,
        \\k = 1
        \\def make() -> Any do
        \\  k = 5
        \\  fn(x: Int) -> Int do x + k end
        \\end
        \\f = make()
        \\k = 100
    );
    try std.testing.expectEqual(@as(i64, 6), (try run(code.allocator(), &eval, "f(1)")).integer);
}

test "a fn literal sees the top level as it was when it was made, and globals defined later" {
    var code = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer code.deinit();
    var heaps = [2]std.heap.ArenaAllocator{
        std.heap.ArenaAllocator.init(std.testing.allocator),
        std.heap.ArenaAllocator.init(std.testing.allocator),
    };
    defer heaps[0].deinit();
    defer heaps[1].deinit();

    var eval = Evaluator.init(heaps[0].allocator());
    eval.code_allocator = code.allocator();
    // A fn literal no longer copies the top level into its captures; it reads
    // the top level in place, as far as it went when the fn was made. These
    // are the answers the copy gave.
    _ = try run(code.allocator(), &eval,
        \\x = 1
        \\f = fn() -> Int do x end
        \\x = 2
        \\def g() -> Int do 10 end
        \\h = fn() -> Int do g() end
        \\def g() -> Int do 20 end
        \\k = fn() -> Int do later() end
        \\def later() -> Int do 99 end
        \\def outer() -> Any do fn() -> Int do later2() end end
        \\kk = outer()
        \\def later2() -> Int do 7 end
        \\def shadow_caller(cb: Fn) -> Int do
        \\  x = 100
        \\  cb()
        \\end
        \\def uses_x() -> Int do x end
    );
    for (0..2) |round| {
        // the snapshot: the x and the g there were when the fn was made
        try std.testing.expectEqual(@as(i64, 1), (try run(code.allocator(), &eval, "f()")).integer);
        try std.testing.expectEqual(@as(i64, 10), (try run(code.allocator(), &eval, "h()")).integer);
        // a name the top level did not have yet is found when it is called
        try std.testing.expectEqual(@as(i64, 99), (try run(code.allocator(), &eval, "k()")).integer);
        try std.testing.expectEqual(@as(i64, 7), (try run(code.allocator(), &eval, "kk()")).integer);
        // what the fn saw of the top level beats the caller's local of that name
        try std.testing.expectEqual(@as(i64, 1), (try run(code.allocator(), &eval, "shadow_caller(f)")).integer);
        // a top-level def reads the top level live: last definition wins
        try std.testing.expectEqual(@as(i64, 2), (try run(code.allocator(), &eval, "uses_x()")).integer);
        try std.testing.expectEqual(@as(i64, 20), (try run(code.allocator(), &eval, "g()")).integer);
        if (round == 0) {
            // and all of it survives compaction, which rebuilds the index
            try compact(&eval, heaps[1].allocator(), std.testing.allocator);
            _ = heaps[0].reset(.free_all);
        }
    }
}

test "a fn literal tail-calling another keeps seeing what it saw of the top level" {
    var code = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer code.deinit();
    var heap = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer heap.deinit();
    var eval = Evaluator.init(heap.allocator());
    eval.code_allocator = code.allocator();
    // `b` is made before `w` exists, `a` while it is 5, and `a` tail-calls
    // `b`, handing it the frame. `b` has no `w` of its own, so it reads the
    // `w` that `a` saw -- which used to sit in the frame as one of `a`'s
    // copied captures, and is now `a`'s mark (Scope.left_mark). Without it
    // `b` falls through to the live top level and answers 51.
    _ = try run(code.allocator(), &eval,
        \\b = fn(n: Int) -> Int do n + w end
        \\w = 5
        \\a = fn(n: Int) -> Int do b(n) end
        \\w = 50
    );
    try std.testing.expectEqual(@as(i64, 6), (try run(code.allocator(), &eval, "a(1)")).integer);
    try std.testing.expectEqual(@as(i64, 51), (try run(code.allocator(), &eval, "b(1)")).integer);
}

test "redefining an actor updates its running instances and keeps their state" {
    var code = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer code.deinit();
    var heaps = [2]std.heap.ArenaAllocator{
        std.heap.ArenaAllocator.init(std.testing.allocator),
        std.heap.ArenaAllocator.init(std.testing.allocator),
    };
    defer heaps[0].deinit();
    defer heaps[1].deinit();

    var eval = Evaluator.init(heaps[0].allocator());
    eval.code_allocator = code.allocator();
    _ = try run(code.allocator(), &eval,
        \\actor Tally do
        \\  state n: Int :: 0
        \\  state old: String :: "gone soon"
        \\  on :add(k: Int) do
        \\    become n: n + k
        \\    reply n + k
        \\  end
        \\  on :show do reply "n=#{n}" end
        \\end
        \\t = spawn Tally
        \\t <- :add(5)
        \\t <- :add(2)
    );
    try std.testing.expectEqualStrings("n=7", (try run(code.allocator(), &eval, "t <- :show")).string);

    _ = try run(code.allocator(), &eval,
        \\actor Tally do
        \\  state n: Int :: 0
        \\  state label: String :: "total"
        \\  on :add(k: Int) do
        \\    become n: n + k * 10
        \\    reply n + k * 10
        \\  end
        \\  on :show do reply "#{label}: #{n}" end
        \\end
    );
    try compact(&eval, heaps[1].allocator(), std.testing.allocator);
    _ = heaps[0].reset(.free_all);

    // the running instance: new handlers, its n kept, the new field defaulted
    try std.testing.expectEqualStrings("total: 7", (try run(code.allocator(), &eval, "t <- :show")).string);
    try std.testing.expectEqual(@as(i64, 17), (try run(code.allocator(), &eval, "t <- :add(1)")).integer);
    // a new instance gets the new definition too
    try std.testing.expectEqualStrings("total: 0", (try run(code.allocator(), &eval, "u = spawn Tally\nu <- :show")).string);
}

test "drop_unreachable keeps every actor a value can name, and only those" {
    var code = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer code.deinit();
    var heap_a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer heap_a.deinit();
    var heap_b = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer heap_b.deinit();

    var eval = Evaluator.init(heap_a.allocator());
    _ = try run(code.allocator(), &eval,
        \\actor Box do
        \\  state held: Any :: nil
        \\  state n: Int :: 0
        \\  on :hold(x: Any) do become held: x end
        \\  on :held do reply held end
        \\  on :bump do become n: n + 1 end
        \\  on :n do reply n end
        \\end
        \\def scratch(i: Int) -> Int do
        \\  b = spawn Box
        \\  b <- :bump
        \\  b <- :n
        \\end
        \\def many(i: Int) -> Int do
        \\  case i >= 50 do
        \\    true -> i
        \\    false ->
        \\      scratch(i)
        \\      many(i + 1)
        \\  end
        \\end
        \\bound = spawn Box
        \\outer = spawn Box
        \\inner = spawn Box
        \\outer <- :hold(inner)
        \\inner = nil
        \\chain = spawn Box
        \\c2 = spawn Box
        \\c3 = spawn Box
        \\c2 <- :hold(%{next: [c3]})
        \\chain <- :hold({c2})
        \\c2 = nil
        \\c3 = nil
        \\in_closure = fn() do spawn Box end
        \\kept_by_fn = spawn Box
        \\f = fn() do kept_by_fn end
        \\kept_by_fn = nil
        \\many(0)
    );
    // 7 kept (bound, outer, the one outer holds, chain, c2, c3, kept_by_fn)
    // plus 50 that scratch/1 spawned and let go.
    try std.testing.expectEqual(@as(usize, 57), eval.registry.instances.items.len);

    const dropped = try compactWith(&eval, heap_b.allocator(), std.testing.allocator, .drop_unreachable);
    _ = heap_a.reset(.free_all);
    try std.testing.expectEqual(@as(usize, 50), dropped);
    try std.testing.expectEqual(@as(usize, 7), eval.registry.instances.items.len);

    // What was kept still works, including what is reachable only through
    // another actor's state, a tuple, a map inside a list, or a closure.
    _ = try run(code.allocator(), &eval, "(outer <- :held) <- :bump");
    try std.testing.expectEqual(@as(i64, 1), (try run(code.allocator(), &eval, "(outer <- :held) <- :n")).integer);
    try std.testing.expectEqual(@as(i64, 0), (try run(code.allocator(), &eval, "(head(lookup(elem(chain <- :held, 0) <- :held, :next))) <- :n")).integer);
    try std.testing.expectEqual(@as(i64, 0), (try run(code.allocator(), &eval, "f() <- :n")).integer);
    try std.testing.expectEqual(@as(i64, 0), (try run(code.allocator(), &eval, "bound <- :n")).integer);
}

test "keep_all still keeps every actor" {
    var code = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer code.deinit();
    var heap_a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer heap_a.deinit();
    var heap_b = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer heap_b.deinit();

    var eval = Evaluator.init(heap_a.allocator());
    _ = try run(code.allocator(), &eval,
        \\actor Box do
        \\  state n: Int :: 0
        \\end
        \\def one(i: Int) -> Int do
        \\  b = spawn Box
        \\  i
        \\end
        \\one(1)
        \\one(2)
    );
    try std.testing.expectEqual(@as(usize, 0), try compactWith(&eval, heap_b.allocator(), std.testing.allocator, .keep_all));
    _ = heap_a.reset(.free_all);
    try std.testing.expectEqual(@as(usize, 2), eval.registry.instances.items.len);
}
