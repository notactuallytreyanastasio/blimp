const std = @import("std");
const Value = @import("value.zig").Value;
const Mailbox = @import("mailbox.zig").Mailbox;

/// An opaque handle to a spawned actor instance.
pub const ActorRef = struct {
    id: u64, // unique instance ID
    type_name: []const u8, // "Counter", "Shop.Checkout"
};

/// Status of a spawned actor instance.
pub const ActorStatus = enum {
    idle,
    running,
    waiting, // blocked on empty mailbox
    dead,
};

/// An instance's state fields in the shape `Scope.captured` borrows, so a
/// handler can be lent them instead of defining them one by one.
///
/// This is a derived copy of `ActorEntry.state_fields`, in the same order,
/// and `become` keeps it in step. A running handler holds a pointer to one
/// of these and counts itself in `borrowers`; `become` writes in place only
/// while no handler holds it, and otherwise swaps in a fresh copy, so the
/// handler that is running (and every handler it called) keeps the values it
/// started with.
pub const StateLend = struct {
    items: []Value.CapturedBinding,
    names: u64,
    borrowers: u32 = 0,
};

/// A spawned actor instance in the registry.
pub const ActorEntry = struct {
    ref: ActorRef,
    state_fields: []Value.MapEntry, // current mutable state
    handlers: []const Value.HandlerDef, // from the template
    status: ActorStatus,
    mailbox: Mailbox, // pending messages
    reductions: u32 = 4000, // remaining reductions this timeslice
    /// Built on the first send, dropped by anything that replaces
    /// `state_fields` wholesale (migrate, restart) and left null by a
    /// compaction, which builds entries without it.
    lent: ?*StateLend = null,
};

/// A registered actor template (from an actor definition).
pub const ActorTemplate = struct {
    name: []const u8,
    default_state: []const Value.MapEntry, // defaults from state definitions
    handlers: []const Value.HandlerDef,
};

/// The actor registry: owns templates and spawned instances.
pub const Registry = struct {
    allocator: std.mem.Allocator,
    templates: std.ArrayList(ActorTemplate),
    /// Instances are boxed, not stored inline.  `getInstance` hands out a
    /// `*ActorEntry` that the evaluator keeps for the whole of a handler
    /// body, and a handler body can spawn -- in an argument, on the right
    /// of a `become`, anywhere.  Storing entries by value would let that
    /// spawn's append reallocate the backing array and leave every
    /// outstanding pointer dangling.  A box stays put.
    instances: std.ArrayList(*ActorEntry),
    /// `by_id[id]` is the instance with that id, or null once a compaction
    /// dropped it.  Ids are dense and never reused, so this is one slot per
    /// actor ever spawned, and `getInstance` is one load.  It used to scan
    /// `instances`, which made every send cost as much as the number of
    /// actors alive: a Temper program, where every object is an actor,
    /// paid 40 us per field read once a few thousand objects existed.
    by_id: std.ArrayList(?*ActorEntry),
    /// The ids whose mailbox is not empty, as a two-level bitset: `pending`
    /// has bit `id` set, `pending_words` has bit `w` set when `pending[w]`
    /// is not zero.  `runScheduler` used to walk every instance looking for
    /// mail; with an actor per object that was a walk of thousands after
    /// every async send.  Ids ascend with instance order, so "the smallest
    /// pending id above the cursor" visits actors in the order the walk did.
    /// The invariant is: bit set if and only if the mailbox is non-empty.
    /// `send` sets it, `processMailboxMessage` clears it when it empties the
    /// mailbox, and `reindex` rebuilds it from the mailboxes after a
    /// compaction.
    pending: std.ArrayList(u64),
    pending_words: std.ArrayList(u64),
    pending_count: usize = 0,
    next_id: u64,

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{
            .allocator = allocator,
            .templates = .{ .items = &.{}, .capacity = 0 },
            .instances = .{ .items = &.{}, .capacity = 0 },
            .by_id = .{ .items = &.{}, .capacity = 0 },
            .pending = .{ .items = &.{}, .capacity = 0 },
            .pending_words = .{ .items = &.{}, .capacity = 0 },
            .next_id = 1,
        };
    }

    /// Register an actor template (from an actor definition).
    ///
    /// Defining an actor that already exists replaces it, and every running
    /// instance of it is moved onto the new definition: its handlers become
    /// the new ones, a state field both versions have keeps the instance's
    /// value, a field only the new one has starts at its default, and a
    /// field the new one dropped is gone. This used to append a second
    /// template that `lookupTemplate`, returning the first match, never
    /// found, and instances kept the handler table they were spawned with:
    /// a redefinition in a running program was silently ignored.
    pub fn registerTemplate(self: *Registry, name: []const u8, default_state: []const Value.MapEntry, handlers: []const Value.HandlerDef) void {
        for (self.templates.items) |*tmpl| {
            if (!std.mem.eql(u8, tmpl.name, name)) continue;
            tmpl.default_state = default_state;
            tmpl.handlers = handlers;
            for (self.instances.items) |entry| {
                if (std.mem.eql(u8, entry.ref.type_name, name)) self.migrate(entry, tmpl);
            }
            return;
        }
        self.templates.append(self.allocator, .{
            .name = name,
            .default_state = default_state,
            .handlers = handlers,
        }) catch {};
    }

    fn migrate(self: *Registry, entry: *ActorEntry, template: *const ActorTemplate) void {
        const state = self.allocator.alloc(Value.MapEntry, template.default_state.len) catch return;
        for (template.default_state, 0..) |field, i| {
            state[i] = field;
            for (entry.state_fields) |old| {
                if (std.mem.eql(u8, old.key, field.key)) {
                    state[i] = .{ .key = field.key, .val = old.val };
                    break;
                }
            }
        }
        entry.state_fields = state;
        entry.lent = null;
        entry.handlers = template.handlers;
    }

    /// Look up a template by name.
    pub fn lookupTemplate(self: *const Registry, name: []const u8) ?*const ActorTemplate {
        for (self.templates.items) |*tmpl| {
            if (std.mem.eql(u8, tmpl.name, name)) return tmpl;
        }
        return null;
    }

    /// Spawn a new instance from a template with optional state overrides.
    pub fn spawn(self: *Registry, template: *const ActorTemplate, overrides: []const Value.MapEntry) ActorRef {
        const ref = ActorRef{
            .id = self.next_id,
            .type_name = template.name,
        };
        self.next_id += 1;

        // Copy default state, applying overrides
        const state = self.allocator.alloc(Value.MapEntry, template.default_state.len) catch return ref;
        for (template.default_state, 0..) |default_field, i| {
            var found_override = false;
            for (overrides) |ov| {
                if (std.mem.eql(u8, ov.key, default_field.key)) {
                    state[i] = .{ .key = default_field.key, .val = ov.val };
                    found_override = true;
                    break;
                }
            }
            if (!found_override) {
                state[i] = default_field;
            }
        }

        const entry = self.allocator.create(ActorEntry) catch return ref;
        entry.* = .{
            .ref = ref,
            .state_fields = state,
            .handlers = template.handlers,
            .status = .idle,
            .mailbox = Mailbox.init(),
        };
        self.instances.append(self.allocator, entry) catch {};
        self.indexEntry(entry);

        return ref;
    }

    fn indexEntry(self: *Registry, entry: *ActorEntry) void {
        const id: usize = @intCast(entry.ref.id);
        while (self.by_id.items.len <= id) self.by_id.append(self.allocator, null) catch return;
        self.by_id.items[id] = entry;
    }

    /// Rebuild `by_id` from `instances`, in the registry's current allocator.
    /// A compaction copies the instances into a new allocator and swaps the
    /// list; the index lived in the old one and must follow.
    pub fn reindex(self: *Registry) void {
        self.by_id = .{ .items = &.{}, .capacity = 0 };
        self.pending = .{ .items = &.{}, .capacity = 0 };
        self.pending_words = .{ .items = &.{}, .capacity = 0 };
        self.pending_count = 0;
        for (self.instances.items) |entry| {
            self.indexEntry(entry);
            if (!entry.mailbox.isEmpty()) self.markPending(entry.ref.id);
        }
    }

    /// Put a message in `entry`'s mailbox and note that it has mail.
    pub fn send(self: *Registry, entry: *ActorEntry, msg: @import("mailbox.zig").Message) void {
        entry.mailbox.enqueue(self.allocator, msg);
        self.markPending(entry.ref.id);
    }

    pub fn markPending(self: *Registry, id: u64) void {
        const w: usize = @intCast(id >> 6);
        const bit = @as(u64, 1) << @intCast(id & 63);
        while (self.pending.items.len <= w) self.pending.append(self.allocator, 0) catch return;
        const sw = w >> 6;
        while (self.pending_words.items.len <= sw) self.pending_words.append(self.allocator, 0) catch return;
        if (self.pending.items[w] & bit != 0) return;
        self.pending.items[w] |= bit;
        self.pending_words.items[sw] |= @as(u64, 1) << @intCast(w & 63);
        self.pending_count += 1;
    }

    pub fn clearPending(self: *Registry, id: u64) void {
        const w: usize = @intCast(id >> 6);
        if (w >= self.pending.items.len) return;
        const bit = @as(u64, 1) << @intCast(id & 63);
        if (self.pending.items[w] & bit == 0) return;
        self.pending.items[w] &= ~bit;
        self.pending_count -= 1;
        if (self.pending.items[w] == 0) self.pending_words.items[w >> 6] &= ~(@as(u64, 1) << @intCast(w & 63));
    }

    /// The smallest id >= `from` whose mailbox has mail.
    pub fn nextPending(self: *const Registry, from: u64) ?u64 {
        if (self.pending_count == 0) return null;
        const w: usize = @intCast(from >> 6);
        if (w >= self.pending.items.len) return null;
        const m = self.pending.items[w] & (~@as(u64, 0) << @intCast(from & 63));
        if (m != 0) return @as(u64, w) * 64 + @ctz(m);
        const s = w + 1;
        var sw = s >> 6;
        if (sw >= self.pending_words.items.len) return null;
        var sm = self.pending_words.items[sw] & (~@as(u64, 0) << @intCast(s & 63));
        while (true) {
            if (sm != 0) {
                const nw = sw * 64 + @ctz(sm);
                return @as(u64, nw) * 64 + @ctz(self.pending.items[nw]);
            }
            sw += 1;
            if (sw >= self.pending_words.items.len) return null;
            sm = self.pending_words.items[sw];
        }
    }

    /// Look up a spawned instance by ref.  The pointer stays valid for the
    /// life of the instance, including across later spawns.
    pub fn getInstance(self: *Registry, ref: ActorRef) ?*ActorEntry {
        const id: usize = @intCast(ref.id);
        if (id < self.by_id.items.len) return self.by_id.items[id];
        return null;
    }

    /// Restart a single actor: reset its state to template defaults.
    pub fn restartActor(self: *Registry, ref: ActorRef) void {
        const entry = self.getInstance(ref) orelse return;
        const template = self.lookupTemplate(ref.type_name) orelse return;

        // Reset state to defaults
        for (template.default_state, 0..) |default_field, i| {
            if (i < entry.state_fields.len) {
                entry.state_fields[i] = default_field;
            }
        }
        entry.lent = null;
        entry.status = .idle;
    }

    /// Restart all children of a supervisor.
    /// Children are actors whose type_name starts with supervisor_name + "."
    pub fn restartChildren(self: *Registry, supervisor_name: []const u8) void {
        for (self.instances.items) |entry| {
            const name = entry.ref.type_name;
            // Check if this actor is a child of the supervisor
            if (name.len > supervisor_name.len + 1 and
                std.mem.startsWith(u8, name, supervisor_name) and
                name[supervisor_name.len] == '.')
            {
                const template = self.lookupTemplate(name) orelse continue;
                // Reset state to defaults
                for (template.default_state, 0..) |default_field, i| {
                    if (i < entry.state_fields.len) {
                        entry.state_fields[i] = default_field;
                    }
                }
                entry.lent = null;
                entry.status = .idle;
            }
        }
    }

    /// Get all children of a supervisor (for introspection).
    pub fn getChildren(self: *const Registry, supervisor_name: []const u8) []const ActorRef {
        var children: std.ArrayList(ActorRef) = .{ .items = &.{}, .capacity = 0 };
        for (self.instances.items) |entry| {
            const name = entry.ref.type_name;
            if (name.len > supervisor_name.len + 1 and
                std.mem.startsWith(u8, name, supervisor_name) and
                name[supervisor_name.len] == '.')
            {
                children.append(self.allocator, entry.ref) catch {};
            }
        }
        return children.items;
    }
};

// ============================================================
// Tests
// ============================================================

test "register and lookup template" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry = Registry.init(alloc);

    const default_val = try alloc.create(Value);
    default_val.* = Value{ .integer = 0 };
    const defaults = try alloc.alloc(Value.MapEntry, 1);
    defaults[0] = .{ .key = "count", .val = default_val };

    const handlers: []const Value.HandlerDef = &.{};
    registry.registerTemplate("Counter", defaults, handlers);

    const tmpl = registry.lookupTemplate("Counter");
    try std.testing.expect(tmpl != null);
    try std.testing.expectEqualStrings("Counter", tmpl.?.name);
    try std.testing.expectEqual(@as(usize, 1), tmpl.?.default_state.len);
}

test "lookup missing template returns null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var registry = Registry.init(arena.allocator());
    try std.testing.expect(registry.lookupTemplate("Missing") == null);
}

test "spawn creates unique refs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry = Registry.init(alloc);

    const default_val = try alloc.create(Value);
    default_val.* = Value{ .integer = 0 };
    const defaults = try alloc.alloc(Value.MapEntry, 1);
    defaults[0] = .{ .key = "count", .val = default_val };

    const handlers: []const Value.HandlerDef = &.{};
    registry.registerTemplate("Counter", defaults, handlers);

    const tmpl = registry.lookupTemplate("Counter").?;
    const ref1 = registry.spawn(tmpl, &.{});
    const ref2 = registry.spawn(tmpl, &.{});

    try std.testing.expect(ref1.id != ref2.id);
    try std.testing.expectEqualStrings("Counter", ref1.type_name);
    try std.testing.expectEqualStrings("Counter", ref2.type_name);
}

test "spawn with overrides" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry = Registry.init(alloc);

    const default_val = try alloc.create(Value);
    default_val.* = Value{ .integer = 0 };
    const defaults = try alloc.alloc(Value.MapEntry, 1);
    defaults[0] = .{ .key = "count", .val = default_val };

    registry.registerTemplate("Counter", defaults, &.{});

    const tmpl = registry.lookupTemplate("Counter").?;

    const override_val = try alloc.create(Value);
    override_val.* = Value{ .integer = 10 };
    const overrides = try alloc.alloc(Value.MapEntry, 1);
    overrides[0] = .{ .key = "count", .val = override_val };

    const ref = registry.spawn(tmpl, overrides);
    const entry = registry.getInstance(ref);
    try std.testing.expect(entry != null);
    try std.testing.expect(entry.?.state_fields[0].val.eql(Value{ .integer = 10 }));
}

test "getInstance returns correct entry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry = Registry.init(alloc);

    const default_val = try alloc.create(Value);
    default_val.* = Value{ .integer = 0 };
    const defaults = try alloc.alloc(Value.MapEntry, 1);
    defaults[0] = .{ .key = "count", .val = default_val };

    registry.registerTemplate("Counter", defaults, &.{});

    const tmpl = registry.lookupTemplate("Counter").?;
    const ref1 = registry.spawn(tmpl, &.{});
    const ref2 = registry.spawn(tmpl, &.{});

    const entry1 = registry.getInstance(ref1);
    const entry2 = registry.getInstance(ref2);
    try std.testing.expect(entry1 != null);
    try std.testing.expect(entry2 != null);
    try std.testing.expect(entry1.?.ref.id != entry2.?.ref.id);
}

test "instances have independent state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry = Registry.init(alloc);

    const default_val = try alloc.create(Value);
    default_val.* = Value{ .integer = 0 };
    const defaults = try alloc.alloc(Value.MapEntry, 1);
    defaults[0] = .{ .key = "count", .val = default_val };

    registry.registerTemplate("Counter", defaults, &.{});

    const tmpl = registry.lookupTemplate("Counter").?;
    const ref1 = registry.spawn(tmpl, &.{});
    const ref2 = registry.spawn(tmpl, &.{});

    // Modify state of instance 1
    const entry1 = registry.getInstance(ref1).?;
    const new_val = try alloc.create(Value);
    new_val.* = Value{ .integer = 42 };
    entry1.state_fields[0].val = new_val;

    // Instance 2 should be unaffected
    const entry2 = registry.getInstance(ref2).?;
    try std.testing.expect(entry2.state_fields[0].val.eql(Value{ .integer = 0 }));
}

test "instance pointers survive later spawns" {
    // getInstance hands out a pointer into the instance list and the
    // evaluator holds it for a whole handler body -- during which the
    // handler may spawn.  Growing the list must not move entries out from
    // under that pointer.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry = Registry.init(alloc);

    const default_val = try alloc.create(Value);
    default_val.* = Value{ .integer = 0 };
    const defaults = try alloc.alloc(Value.MapEntry, 1);
    defaults[0] = .{ .key = "count", .val = default_val };
    registry.registerTemplate("Counter", defaults, &.{});

    const tmpl = registry.lookupTemplate("Counter").?;
    const ref = registry.spawn(tmpl, &.{});
    const entry = registry.getInstance(ref).?;

    // Enough spawns to force the backing array to grow several times.
    for (0..64) |_| _ = registry.spawn(tmpl, &.{});

    try std.testing.expectEqual(ref.id, entry.ref.id);
    try std.testing.expectEqual(@as(usize, 1), entry.state_fields.len);
    try std.testing.expect(entry == registry.getInstance(ref).?);
}

test "pending set yields ids in ascending order across word boundaries" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.pending.deinit(std.testing.allocator);
    defer reg.pending_words.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?u64, null), reg.nextPending(0));
    const ids = [_]u64{ 3, 63, 64, 200, 4095, 4096, 9000 };
    for (ids) |id| reg.markPending(id);
    reg.markPending(64); // already set: no double count
    try std.testing.expectEqual(ids.len, reg.pending_count);
    var got: [ids.len]u64 = undefined;
    var n: usize = 0;
    var cursor: u64 = 0;
    while (reg.nextPending(cursor)) |id| : (cursor = id + 1) {
        got[n] = id;
        n += 1;
    }
    try std.testing.expectEqualSlices(u64, &ids, &got);
    reg.clearPending(4096);
    try std.testing.expectEqual(@as(?u64, 9000), reg.nextPending(4096));
    for (ids) |id| reg.clearPending(id);
    try std.testing.expectEqual(@as(usize, 0), reg.pending_count);
    try std.testing.expectEqual(@as(?u64, null), reg.nextPending(0));
}
