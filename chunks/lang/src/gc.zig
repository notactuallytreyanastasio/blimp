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
    var copier = Copier{
        .to = to,
        .values = std.AutoHashMap(usize, *const Value).init(scratch),
        .handlers = std.AutoHashMap(usize, []const Value.HandlerDef).init(scratch),
    };
    defer copier.values.deinit();
    defer copier.handlers.deinit();

    // Build every replacement first, then swap them in, so a failure
    // part-way leaves the evaluator consistent.
    const scopes = try copier.scopes(eval.env.scopes.items);
    const templates = try copier.templates(eval.registry.templates.items);
    const instances = try copier.instances(eval.registry.instances.items);
    const bubble_reason: ?*const Value = if (eval.bubble_reason) |r| try copier.value(r) else null;
    var msg_log: [64]Evaluator.MsgLogEntry = undefined;
    for (0..eval.msg_log_count) |i| {
        const e = eval.msg_log[i];
        msg_log[i] = .{
            .target_id = e.target_id,
            .target_type = try copier.str(e.target_type),
            .message = try copier.str(e.message),
        };
    }

    eval.env.scopes = scopes;
    eval.env.allocator = to;
    eval.registry.templates = templates;
    eval.registry.instances = instances;
    eval.registry.allocator = to;
    eval.bubble_reason = bubble_reason;
    for (0..eval.msg_log_count) |i| eval.msg_log[i] = msg_log[i];
    eval.builtins = BuiltinRegistry.init(to);
    eval.allocator = to;
}

const Copier = struct {
    to: std.mem.Allocator,
    values: std.AutoHashMap(usize, *const Value),
    handlers: std.AutoHashMap(usize, []const Value.HandlerDef),

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
            .actor_ref => |r| .{ .actor_ref = .{ .id = r.id, .type_name = try self.str(r.type_name) } },
            .closure => |c| .{ .closure = .{
                .params = c.params,
                .body = c.body,
                .env = try self.captured(c.env),
                .return_type = try self.optStr(c.return_type),
            } },
            .view_node => |n| .{ .view_node = .{
                .tag = try self.str(n.tag),
                .attrs = try self.attrs(n.attrs),
                .children = try self.valueList(n.children),
            } },
        };
        return nv;
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
            for (scope.bindings.items) |b| {
                bindings.appendAssumeCapacity(.{ .name = try self.str(b.name), .val = try self.value(b.val) });
            }
            out.appendAssumeCapacity(.{ .bindings = bindings });
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

    fn instances(self: *Copier, old: []const registry_mod.ActorEntry) CompactError!std.ArrayList(registry_mod.ActorEntry) {
        var out: std.ArrayList(registry_mod.ActorEntry) = .{ .items = &.{}, .capacity = 0 };
        try out.ensureTotalCapacity(self.to, old.len);
        for (old) |e| {
            out.appendAssumeCapacity(.{
                .ref = .{ .id = e.ref.id, .type_name = try self.str(e.ref.type_name) },
                .state_fields = try self.mapEntries(e.state_fields),
                .handlers = try self.handlerDefs(e.handlers),
                .status = e.status,
                .mailbox = try self.mailbox(e.mailbox),
                .reductions = e.reductions,
            });
        }
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
