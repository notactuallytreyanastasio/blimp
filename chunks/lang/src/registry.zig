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

/// A spawned actor instance in the registry.
pub const ActorEntry = struct {
    ref: ActorRef,
    state_fields: []Value.MapEntry, // current mutable state
    handlers: []const Value.HandlerDef, // from the template
    status: ActorStatus,
    mailbox: Mailbox, // pending messages
    reductions: u32 = 4000, // remaining reductions this timeslice
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
    instances: std.ArrayList(ActorEntry),
    next_id: u64,

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{
            .allocator = allocator,
            .templates = .{ .items = &.{}, .capacity = 0 },
            .instances = .{ .items = &.{}, .capacity = 0 },
            .next_id = 1,
        };
    }

    /// Register an actor template (from an actor definition).
    pub fn registerTemplate(self: *Registry, name: []const u8, default_state: []const Value.MapEntry, handlers: []const Value.HandlerDef) void {
        self.templates.append(self.allocator, .{
            .name = name,
            .default_state = default_state,
            .handlers = handlers,
        }) catch {};
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

        self.instances.append(self.allocator, .{
            .ref = ref,
            .state_fields = state,
            .handlers = template.handlers,
            .status = .idle,
            .mailbox = Mailbox.init(),
        }) catch {};

        return ref;
    }

    /// Look up a spawned instance by ref.
    pub fn getInstance(self: *Registry, ref: ActorRef) ?*ActorEntry {
        for (self.instances.items) |*entry| {
            if (entry.ref.id == ref.id) return entry;
        }
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
        entry.status = .idle;
    }

    /// Restart all children of a supervisor.
    /// Children are actors whose type_name starts with supervisor_name + "."
    pub fn restartChildren(self: *Registry, supervisor_name: []const u8) void {
        for (self.instances.items) |*entry| {
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
