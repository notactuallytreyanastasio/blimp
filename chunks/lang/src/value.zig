const std = @import("std");
const registry_mod = @import("registry.zig");

/// A runtime value in the Blimp language.
pub const Value = union(enum) {
    integer: i64,
    float: f64,
    string: []const u8,
    atom: []const u8,
    boolean: bool,
    nil,
    hole,
    list: []const *const Value,
    tuple: []const *const Value,
    map: []const MapEntry,
    actor_ref: registry_mod.ActorRef,
    closure: Closure,
    view_node: ViewNode,

    pub const ViewNode = struct {
        tag: []const u8,
        attrs: []const ViewAttr,
        children: []const *const Value,

        pub const ViewAttr = struct {
            key: []const u8,
            val: *const Value,
        };
    };

    pub const Closure = struct {
        params: []const @import("ast.zig").Node.HandlerParam, // typed params
        body: []const @import("ast.zig").Node,
        env: []const CapturedBinding,
        return_type: ?[]const u8 = null,
    };

    pub const CapturedBinding = struct {
        name: []const u8,
        val: *const Value,
    };

    pub const MapEntry = struct {
        key: []const u8,
        val: *const Value,
    };

    pub const HandlerDef = struct {
        name: []const u8,
        params: []const @import("ast.zig").Node.HandlerParam,
        guard: ?*const @import("ast.zig").Node,
        body: []const @import("ast.zig").Node,
        bubble_strategy: ?[]const u8 = null,
    };

    pub const ActorInstance = struct {
        name: []const u8,
        state_fields: []MapEntry, // MUTABLE - become updates these
        handlers: []const HandlerDef,
    };

    /// Format a value for display.
    pub fn format(self: Value, writer: anytype) void {
        switch (self) {
            .integer => |n| writer.print("{d}", .{n}) catch {},
            .float => |f| writer.print("{d}", .{f}) catch {},
            .string => |s| writer.print("\"{s}\"", .{s}) catch {},
            .atom => |a| writer.print(":{s}", .{a}) catch {},
            .boolean => |b| writer.print("{}", .{b}) catch {},
            .nil => writer.writeAll("nil") catch {},
            .hole => writer.writeAll("_") catch {},
            .list => |items| {
                writer.writeAll("[") catch {};
                for (items, 0..) |item, i| {
                    if (i > 0) writer.writeAll(", ") catch {};
                    item.format(writer);
                }
                writer.writeAll("]") catch {};
            },
            .tuple => |items| {
                writer.writeAll("{") catch {};
                for (items, 0..) |item, i| {
                    if (i > 0) writer.writeAll(", ") catch {};
                    item.format(writer);
                }
                writer.writeAll("}") catch {};
            },
            .map => |entries| {
                writer.writeAll("%{") catch {};
                for (entries, 0..) |entry, i| {
                    if (i > 0) writer.writeAll(", ") catch {};
                    writer.print("{s}: ", .{entry.key}) catch {};
                    entry.val.format(writer);
                }
                writer.writeAll("}") catch {};
            },
            .actor_ref => |ref| {
                writer.print("ref<{s}:{d}>", .{ ref.type_name, ref.id }) catch {};
            },
            .closure => |c| {
                writer.writeAll("fn(") catch {};
                for (c.params, 0..) |p, i| {
                    if (i > 0) writer.writeAll(", ") catch {};
                    writer.writeAll(p.name) catch {};
                    if (p.type_name) |t| {
                        writer.writeAll(": ") catch {};
                        writer.writeAll(t) catch {};
                    }
                }
                writer.writeAll(")") catch {};
                if (c.return_type) |rt| {
                    writer.writeAll(" -> ") catch {};
                    writer.writeAll(rt) catch {};
                }
                writer.writeAll(" do ... end") catch {};
            },
            .view_node => |node| {
                writer.print("<{s}", .{node.tag}) catch {};
                for (node.attrs) |attr| {
                    writer.print(" {s}=", .{attr.key}) catch {};
                    attr.val.format(writer);
                }
                if (node.children.len == 0) {
                    writer.writeAll(" />") catch {};
                } else {
                    writer.writeAll(">") catch {};
                    for (node.children) |child| {
                        child.format(writer);
                    }
                    writer.print("</{s}>", .{node.tag}) catch {};
                }
            },
        }
    }

    /// Structural equality of two values.
    pub fn eql(a: Value, b: Value) bool {
        const tag_a = std.meta.activeTag(a);
        const tag_b = std.meta.activeTag(b);
        if (tag_a != tag_b) return false;

        return switch (a) {
            .integer => |n| n == b.integer,
            .float => |f| f == b.float,
            .string => |s| std.mem.eql(u8, s, b.string),
            .atom => |s| std.mem.eql(u8, s, b.atom),
            .boolean => |v| v == b.boolean,
            .nil => true,
            .hole => true,
            .list => |items_a| {
                const items_b = b.list;
                if (items_a.len != items_b.len) return false;
                for (items_a, items_b) |ia, ib| {
                    if (!ia.eql(ib.*)) return false;
                }
                return true;
            },
            .tuple => |items_a| {
                const items_b = b.tuple;
                if (items_a.len != items_b.len) return false;
                for (items_a, items_b) |ia, ib| {
                    if (!ia.eql(ib.*)) return false;
                }
                return true;
            },
            .map => |entries_a| {
                const entries_b = b.map;
                if (entries_a.len != entries_b.len) return false;
                for (entries_a, entries_b) |ea, eb| {
                    if (!std.mem.eql(u8, ea.key, eb.key)) return false;
                    if (!ea.val.eql(eb.val.*)) return false;
                }
                return true;
            },
            .actor_ref => |ref_a| {
                const ref_b = b.actor_ref;
                return ref_a.id == ref_b.id;
            },
            .closure => false, // closures are never equal by value
            .view_node => |node_a| {
                const node_b = b.view_node;
                if (!std.mem.eql(u8, node_a.tag, node_b.tag)) return false;
                if (node_a.attrs.len != node_b.attrs.len) return false;
                for (node_a.attrs, node_b.attrs) |aa, ab| {
                    if (!std.mem.eql(u8, aa.key, ab.key)) return false;
                    if (!aa.val.eql(ab.val.*)) return false;
                }
                if (node_a.children.len != node_b.children.len) return false;
                for (node_a.children, node_b.children) |ca, cb| {
                    if (!ca.eql(cb.*)) return false;
                }
                return true;
            },
        };
    }

    /// Truthiness: nil, false, and hole are falsy; everything else (including view nodes) is truthy.
    pub fn truthy(v: Value) bool {
        return switch (v) {
            .nil => false,
            .boolean => |b| b,
            .hole => false,
            else => true,
        };
    }

    /// Human-readable type name for error messages.
    pub fn typeName(v: Value) []const u8 {
        return switch (v) {
            .integer => "Int",
            .float => "Float",
            .string => "String",
            .atom => "Atom",
            .boolean => "Bool",
            .nil => "Nil",
            .hole => "Hole",
            .list => "List",
            .tuple => "Tuple",
            .map => "Map",
            .actor_ref => "ActorRef",
            .closure => "Function",
            .view_node => "ViewNode",
        };
    }
};

// ============================================================
// Tests
// ============================================================

test "format integer" {
    var buf: [64]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const v = Value{ .integer = 42 };
    v.format(stream.writer());
    try std.testing.expectEqualStrings("42", stream.getWritten());
}

test "format float" {
    var buf: [64]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const v = Value{ .float = 3.14 };
    v.format(stream.writer());
    const written = stream.getWritten();
    // Float formatting may vary; check it starts with "3.14"
    try std.testing.expect(written.len > 0);
    try std.testing.expect(written[0] == '3');
}

test "format string" {
    var buf: [64]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const v = Value{ .string = "hello" };
    v.format(stream.writer());
    try std.testing.expectEqualStrings("\"hello\"", stream.getWritten());
}

test "format atom" {
    var buf: [64]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const v = Value{ .atom = "ok" };
    v.format(stream.writer());
    try std.testing.expectEqualStrings(":ok", stream.getWritten());
}

test "format boolean" {
    var buf: [64]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const v = Value{ .boolean = true };
    v.format(stream.writer());
    try std.testing.expectEqualStrings("true", stream.getWritten());
}

test "format nil" {
    var buf: [64]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const v: Value = .nil;
    v.format(stream.writer());
    try std.testing.expectEqualStrings("nil", stream.getWritten());
}

test "format list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const v1 = try alloc.create(Value);
    v1.* = Value{ .integer = 1 };
    const v2 = try alloc.create(Value);
    v2.* = Value{ .integer = 2 };
    const items = try alloc.alloc(*const Value, 2);
    items[0] = v1;
    items[1] = v2;

    var buf: [64]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const v = Value{ .list = items };
    v.format(stream.writer());
    try std.testing.expectEqualStrings("[1, 2]", stream.getWritten());
}

test "format tuple" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const v1 = try alloc.create(Value);
    v1.* = Value{ .atom = "ok" };
    const v2 = try alloc.create(Value);
    v2.* = Value{ .integer = 42 };
    const items = try alloc.alloc(*const Value, 2);
    items[0] = v1;
    items[1] = v2;

    var buf: [64]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const v = Value{ .tuple = items };
    v.format(stream.writer());
    try std.testing.expectEqualStrings("{:ok, 42}", stream.getWritten());
}

test "format map" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const v1 = try alloc.create(Value);
    v1.* = Value{ .string = "bob" };
    const entries = try alloc.alloc(Value.MapEntry, 1);
    entries[0] = .{ .key = "name", .val = v1 };

    var buf: [64]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const v = Value{ .map = entries };
    v.format(stream.writer());
    try std.testing.expectEqualStrings("%{name: \"bob\"}", stream.getWritten());
}

test "eql matching integers" {
    const a = Value{ .integer = 42 };
    const b = Value{ .integer = 42 };
    try std.testing.expect(a.eql(b));
}

test "eql non-matching integers" {
    const a = Value{ .integer = 42 };
    const b = Value{ .integer = 99 };
    try std.testing.expect(!a.eql(b));
}

test "eql different types" {
    const a = Value{ .integer = 42 };
    const b = Value{ .string = "42" };
    try std.testing.expect(!a.eql(b));
}

test "eql matching strings" {
    const a = Value{ .string = "hello" };
    const b = Value{ .string = "hello" };
    try std.testing.expect(a.eql(b));
}

test "eql matching atoms" {
    const a = Value{ .atom = "ok" };
    const b = Value{ .atom = "ok" };
    try std.testing.expect(a.eql(b));
}

test "eql nil" {
    const a: Value = .nil;
    const b: Value = .nil;
    try std.testing.expect(a.eql(b));
}

test "truthy - nil is falsy" {
    const v: Value = .nil;
    try std.testing.expect(!v.truthy());
}

test "truthy - false is falsy" {
    const v = Value{ .boolean = false };
    try std.testing.expect(!v.truthy());
}

test "truthy - true is truthy" {
    const v = Value{ .boolean = true };
    try std.testing.expect(v.truthy());
}

test "truthy - integer is truthy" {
    const v = Value{ .integer = 0 };
    try std.testing.expect(v.truthy());
}

test "truthy - string is truthy" {
    const v = Value{ .string = "" };
    try std.testing.expect(v.truthy());
}

test "truthy - hole is falsy" {
    const v: Value = .hole;
    try std.testing.expect(!v.truthy());
}
