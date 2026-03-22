const std = @import("std");
const ast = @import("ast.zig");

/// Blimp type representation.
/// A tagged union covering all types in the language.
pub const Type = union(enum) {
    int,
    float,
    string,
    bool_type,
    atom,
    nil,
    any,
    never,
    /// Unknown / to-be-inferred type (placeholder).
    hole,

    /// Homogeneous list type: [T]
    list: *const Type,

    /// Map type: %{K => V}
    map: MapType,

    /// Tuple type: {A, B, C}
    tuple: []const Type,

    /// Actor reference type.
    actor: []const u8,

    pub const MapType = struct {
        key: *const Type,
        value: *const Type,
    };

    /// Check structural equality of two types.
    pub fn eql(a: Type, b: Type) bool {
        const tag_a = std.meta.activeTag(a);
        const tag_b = std.meta.activeTag(b);
        if (tag_a != tag_b) return false;

        return switch (a) {
            .int, .float, .string, .bool_type, .atom, .nil, .any, .never, .hole => true,
            .list => |inner_a| inner_a.eql(b.list.*),
            .map => |m_a| {
                const m_b = b.map;
                return m_a.key.eql(m_b.key.*) and m_a.value.eql(m_b.value.*);
            },
            .tuple => |elems_a| {
                const elems_b = b.tuple;
                if (elems_a.len != elems_b.len) return false;
                for (elems_a, elems_b) |ea, eb| {
                    if (!ea.eql(eb)) return false;
                }
                return true;
            },
            .actor => |name_a| std.mem.eql(u8, name_a, b.actor),
        };
    }

    /// Check if `sub` is a subtype of `super`.
    /// Current rules:
    ///   - any type is a subtype of `any`
    ///   - `never` is a subtype of any type
    ///   - `int` is a subtype of `float` (numeric promotion)
    ///   - `nil` is a subtype of any list type (empty list)
    ///   - `hole` matches anything (bidirectional)
    ///   - structural equality otherwise
    pub fn isSubtypeOf(sub: Type, super: Type) bool {
        // hole is a wildcard -- always compatible in either direction
        if (sub == .hole or super == .hole) return true;
        // any is permissive in both directions:
        //   any as super: accepts all types (top type)
        //   any as sub: accepted everywhere (unknown type, not yet constrained)
        if (super == .any or sub == .any) return true;
        // never is bottom -- subtype of everything
        if (sub == .never) return true;
        // int promotes to float
        if (sub == .int and super == .float) return true;
        // nil is compatible with reference-like types (empty/uninitialized):
        //   nil -> list: empty list is a valid list
        //   nil -> map: empty map
        //   nil -> actor: uninitialized actor ref
        //   list -> nil: nil inferred from [] can accept any list
        if (sub == .nil and (super == .list or super == .map or super == .actor)) return true;
        if (sub == .list and super == .nil) return true;
        // Structural subtyping for composite types
        if (sub == .tuple and super == .tuple) {
            if (sub.tuple.len != super.tuple.len) return false;
            for (sub.tuple, super.tuple) |s, sp| {
                if (!s.isSubtypeOf(sp)) return false;
            }
            return true;
        }
        if (sub == .list and super == .list) {
            return sub.list.isSubtypeOf(super.list.*);
        }
        if (sub == .map and super == .map) {
            return sub.map.key.isSubtypeOf(super.map.key.*) and
                sub.map.value.isSubtypeOf(super.map.value.*);
        }
        // structural equality for everything else
        return sub.eql(super);
    }

    /// Format a type for error messages.
    pub fn typeName(self: Type) []const u8 {
        return switch (self) {
            .int => "Int",
            .float => "Float",
            .string => "String",
            .bool_type => "Bool",
            .atom => "Atom",
            .nil => "Nil",
            .any => "Any",
            .never => "Never",
            .hole => "Hole",
            .list => "[...]",
            .map => "%{...}",
            .tuple => "{...}",
            .actor => |n| n,
        };
    }
};

/// Parse a type name string (from the AST) into a Type.
/// Allocates composite types on the given allocator.
pub fn parseTypeName(allocator: std.mem.Allocator, type_str: []const u8) !Type {
    // Primitive types
    if (std.mem.eql(u8, type_str, "Int")) return .int;
    if (std.mem.eql(u8, type_str, "Float")) return .float;
    if (std.mem.eql(u8, type_str, "String")) return .string;
    if (std.mem.eql(u8, type_str, "Bool")) return .bool_type;
    if (std.mem.eql(u8, type_str, "Atom")) return .atom;
    if (std.mem.eql(u8, type_str, "Nil")) return .nil;
    if (std.mem.eql(u8, type_str, "Any")) return .any;

    // List type: [Item], [Int], etc.
    if (type_str.len >= 3 and type_str[0] == '[' and type_str[type_str.len - 1] == ']') {
        const inner_name = type_str[1 .. type_str.len - 1];
        const inner = try parseTypeName(allocator, inner_name);
        const inner_ptr = try allocator.create(Type);
        inner_ptr.* = inner;
        return Type{ .list = inner_ptr };
    }

    // Tuple type: {A, B, C}
    if (type_str.len >= 3 and type_str[0] == '{' and type_str[type_str.len - 1] == '}') {
        const inner = type_str[1 .. type_str.len - 1];
        // Split on commas and parse each element type
        var elem_types: std.ArrayList(Type) = .empty;
        var start: usize = 0;
        var depth: usize = 0;
        for (inner, 0..) |ch, i| {
            if (ch == '[' or ch == '{') depth += 1;
            if (ch == ']' or ch == '}') depth -= 1;
            if (ch == ',' and depth == 0) {
                const part = std.mem.trim(u8, inner[start..i], " ");
                if (part.len > 0) {
                    const t = try parseTypeName(allocator, part);
                    elem_types.append(allocator, t) catch return error.OutOfMemory;
                }
                start = i + 1;
            }
        }
        // Last element
        const last = std.mem.trim(u8, inner[start..], " ");
        if (last.len > 0) {
            const t = try parseTypeName(allocator, last);
            elem_types.append(allocator, t) catch return error.OutOfMemory;
        }
        return Type{ .tuple = elem_types.toOwnedSlice(allocator) catch return error.OutOfMemory };
    }

    // Map type: %{K => V}
    if (type_str.len >= 5 and type_str[0] == '%' and type_str[1] == '{' and type_str[type_str.len - 1] == '}') {
        const inner = type_str[2 .. type_str.len - 1];
        // Find " => " separator
        if (std.mem.indexOf(u8, inner, "=>")) |sep| {
            const key_str = std.mem.trim(u8, inner[0..sep], " ");
            const val_str = std.mem.trim(u8, inner[sep + 2 ..], " ");
            const key_type = try parseTypeName(allocator, key_str);
            const val_type = try parseTypeName(allocator, val_str);
            const key_ptr = try allocator.create(Type);
            key_ptr.* = key_type;
            const val_ptr = try allocator.create(Type);
            val_ptr.* = val_type;
            return Type{ .map = .{ .key = key_ptr, .value = val_ptr } };
        }
    }

    // Anything else starting with uppercase is an actor type
    if (type_str.len > 0 and type_str[0] >= 'A' and type_str[0] <= 'Z') {
        return Type{ .actor = type_str };
    }

    // Unknown type -- return hole
    return .hole;
}

/// Type environment: maps variable names to types with lexical scope support.
pub const TypeEnv = struct {
    /// Each scope is a list of (name, type) bindings.
    scopes: std.ArrayList(Scope),
    allocator: std.mem.Allocator,

    const Binding = struct {
        name: []const u8,
        ty: Type,
    };

    const Scope = struct {
        bindings: std.ArrayList(Binding),
    };

    pub fn init(allocator: std.mem.Allocator) TypeEnv {
        var env = TypeEnv{
            .scopes = .{ .items = &.{}, .capacity = 0 },
            .allocator = allocator,
        };
        // Push the global scope
        env.pushScope();
        return env;
    }

    /// Push a new scope (e.g., entering a message handler body).
    pub fn pushScope(self: *TypeEnv) void {
        self.scopes.append(self.allocator, .{
            .bindings = .{ .items = &.{}, .capacity = 0 },
        }) catch {};
    }

    /// Pop the current scope (e.g., leaving a handler body).
    pub fn popScope(self: *TypeEnv) void {
        if (self.scopes.items.len > 0) {
            _ = self.scopes.pop();
        }
    }

    /// Define a variable in the current (innermost) scope.
    pub fn define(self: *TypeEnv, name_str: []const u8, ty: Type) void {
        if (self.scopes.items.len == 0) return;
        const current = &self.scopes.items[self.scopes.items.len - 1];
        current.bindings.append(self.allocator, .{ .name = name_str, .ty = ty }) catch {};
    }

    /// Look up a variable, searching from innermost to outermost scope.
    pub fn lookup(self: *const TypeEnv, name_str: []const u8) ?Type {
        var i: usize = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            const scope = self.scopes.items[i];
            // Search backwards for most recent binding
            var j: usize = scope.bindings.items.len;
            while (j > 0) {
                j -= 1;
                if (std.mem.eql(u8, scope.bindings.items[j].name, name_str)) {
                    return scope.bindings.items[j].ty;
                }
            }
        }
        return null;
    }
};

// ============================================================
// Tests
// ============================================================

test "type equality - primitives" {
    const t_int: Type = .int;
    const t_float: Type = .float;
    const t_int2: Type = .int;

    try std.testing.expect(t_int.eql(t_int2));
    try std.testing.expect(!t_int.eql(t_float));
}

test "type equality - list" {
    const inner_a: Type = .int;
    const inner_b: Type = .int;
    const inner_c: Type = .float;

    const list_a = Type{ .list = &inner_a };
    const list_b = Type{ .list = &inner_b };
    const list_c = Type{ .list = &inner_c };

    try std.testing.expect(list_a.eql(list_b));
    try std.testing.expect(!list_a.eql(list_c));
}

test "type equality - tuple" {
    const elems_a = [_]Type{ .int, .string };
    const elems_b = [_]Type{ .int, .string };
    const elems_c = [_]Type{ .int, .float };

    const tuple_a = Type{ .tuple = &elems_a };
    const tuple_b = Type{ .tuple = &elems_b };
    const tuple_c = Type{ .tuple = &elems_c };

    try std.testing.expect(tuple_a.eql(tuple_b));
    try std.testing.expect(!tuple_a.eql(tuple_c));
}

test "type equality - actor" {
    const a1 = Type{ .actor = "Counter" };
    const a2 = Type{ .actor = "Counter" };
    const a3 = Type{ .actor = "Shop" };

    try std.testing.expect(a1.eql(a2));
    try std.testing.expect(!a1.eql(a3));
}

test "subtype - any accepts everything" {
    const t_int: Type = .int;
    const t_str: Type = .string;
    const t_nil: Type = .nil;
    const t_any: Type = .any;

    try std.testing.expect(t_int.isSubtypeOf(t_any));
    try std.testing.expect(t_str.isSubtypeOf(t_any));
    try std.testing.expect(t_nil.isSubtypeOf(t_any));
}

test "subtype - never is bottom" {
    const t_never: Type = .never;
    const t_int: Type = .int;
    const t_str: Type = .string;
    const t_any: Type = .any;

    try std.testing.expect(t_never.isSubtypeOf(t_int));
    try std.testing.expect(t_never.isSubtypeOf(t_str));
    try std.testing.expect(t_never.isSubtypeOf(t_any));
}

test "subtype - int promotes to float" {
    const t_int: Type = .int;
    const t_float: Type = .float;

    try std.testing.expect(t_int.isSubtypeOf(t_float));
    try std.testing.expect(!t_float.isSubtypeOf(t_int));
}

test "subtype - hole is wildcard" {
    const t_hole: Type = .hole;
    const t_int: Type = .int;

    try std.testing.expect(t_hole.isSubtypeOf(t_int));
    try std.testing.expect(t_int.isSubtypeOf(t_hole));
}

test "subtype - nil is empty list" {
    const inner: Type = .int;
    const list_type = Type{ .list = &inner };
    const t_nil: Type = .nil;
    try std.testing.expect(t_nil.isSubtypeOf(list_type));
}

test "parseTypeName - primitives" {
    const int_t = try parseTypeName(std.testing.allocator, "Int");
    try std.testing.expect(int_t.eql(.int));

    const float_t = try parseTypeName(std.testing.allocator, "Float");
    try std.testing.expect(float_t.eql(.float));

    const string_t = try parseTypeName(std.testing.allocator, "String");
    try std.testing.expect(string_t.eql(.string));

    const bool_t = try parseTypeName(std.testing.allocator, "Bool");
    try std.testing.expect(bool_t.eql(.bool_type));

    const atom_t = try parseTypeName(std.testing.allocator, "Atom");
    try std.testing.expect(atom_t.eql(.atom));
}

test "parseTypeName - list type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const list_t = try parseTypeName(arena.allocator(), "[Int]");
    try std.testing.expect(list_t == .list);
    try std.testing.expect(list_t.list.eql(.int));
}

test "parseTypeName - actor type" {
    const actor_t = try parseTypeName(std.testing.allocator, "Counter");
    try std.testing.expect(actor_t == .actor);
    try std.testing.expectEqualStrings("Counter", actor_t.actor);
}

test "parseTypeName - tuple type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tuple_t = try parseTypeName(arena.allocator(), "{Atom, Int}");
    try std.testing.expect(tuple_t == .tuple);
    try std.testing.expectEqual(@as(usize, 2), tuple_t.tuple.len);
    try std.testing.expect(tuple_t.tuple[0].eql(.atom));
    try std.testing.expect(tuple_t.tuple[1].eql(.int));
}

test "parseTypeName - triple tuple type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tuple_t = try parseTypeName(arena.allocator(), "{Atom, String, Int}");
    try std.testing.expect(tuple_t == .tuple);
    try std.testing.expectEqual(@as(usize, 3), tuple_t.tuple.len);
    try std.testing.expect(tuple_t.tuple[0].eql(.atom));
    try std.testing.expect(tuple_t.tuple[1].eql(.string));
    try std.testing.expect(tuple_t.tuple[2].eql(.int));
}

test "parseTypeName - map type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const map_t = try parseTypeName(arena.allocator(), "%{String => Int}");
    try std.testing.expect(map_t == .map);
    try std.testing.expect(map_t.map.key.eql(.string));
    try std.testing.expect(map_t.map.value.eql(.int));
}

test "TypeEnv - define and lookup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var env = TypeEnv.init(arena.allocator());
    env.define("count", .int);
    env.define("name", .string);

    try std.testing.expect(env.lookup("count").?.eql(.int));
    try std.testing.expect(env.lookup("name").?.eql(.string));
    try std.testing.expect(env.lookup("missing") == null);
}

test "TypeEnv - nested scopes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var env = TypeEnv.init(arena.allocator());
    env.define("x", .int);

    env.pushScope();
    env.define("y", .string);
    // Inner scope sees both x and y
    try std.testing.expect(env.lookup("x").?.eql(.int));
    try std.testing.expect(env.lookup("y").?.eql(.string));

    env.popScope();
    // After pop, y is gone
    try std.testing.expect(env.lookup("x").?.eql(.int));
    try std.testing.expect(env.lookup("y") == null);
}

test "TypeEnv - inner scope shadows outer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var env = TypeEnv.init(arena.allocator());
    env.define("x", .int);

    env.pushScope();
    env.define("x", .string);
    // Inner scope shadows outer
    try std.testing.expect(env.lookup("x").?.eql(.string));

    env.popScope();
    // After pop, x reverts to int
    try std.testing.expect(env.lookup("x").?.eql(.int));
}
