const std = @import("std");
const Value = @import("value.zig").Value;
const Environment = @import("env.zig").Environment;
const Registry = @import("registry.zig");
const BuiltinRegistry = @import("builtins.zig").BuiltinRegistry;
const Evaluator = @import("eval.zig").Evaluator;

/// A completion candidate with metadata for display and auto-fill.
pub const Completion = struct {
    /// What to display: "count_up(counter: Counter) -> Int"
    label: []const u8,
    /// What to insert when accepted: "count_up(my_counter)"
    insert: []const u8,
    /// The kind of completion for grouping/icons
    kind: Kind,
    /// Sort priority (lower = better match)
    score: u32,

    pub const Kind = enum {
        variable,
        function,
        builtin,
        actor_template,
        actor_handler,
        keyword,
    };
};

/// The completion engine. Queries evaluator state to produce ranked candidates.
pub const CompletionEngine = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) CompletionEngine {
        return .{ .allocator = allocator };
    }

    /// Get completions for a partial input string given the current evaluator state.
    pub fn complete(self: *CompletionEngine, prefix: []const u8, eval: *const Evaluator) []const Completion {
        var results: std.ArrayList(Completion) = .{ .items = &.{}, .capacity = 0 };

        // 1. Variables in scope (includes user-defined functions via def)
        const bindings = eval.env.allBindings(self.allocator);
        for (bindings) |binding| {
            if (startsWith(binding.name, prefix)) {
                const completion = self.makeVarCompletion(binding.name, binding.val, eval, prefix);
                results.append(self.allocator, completion) catch {};
            }
        }

        // 2. Builtins -- derived from the actual builtin registry
        for (eval.builtins.entries.items) |entry| {
            if (startsWith(entry.name, prefix)) {
                results.append(self.allocator, .{
                    .label = std.fmt.allocPrint(self.allocator, "{s}()", .{entry.name}) catch entry.name,
                    .insert = std.fmt.allocPrint(self.allocator, "{s}(", .{entry.name}) catch entry.name,
                    .kind = .builtin,
                    .score = prefixScore(entry.name, prefix) + 10,
                }) catch {};
            }
        }
        // Higher-order builtins (not in the registry, handled specially in evalFuncCall)
        const ho_builtins = [_][]const u8{ "map", "filter", "reduce", "each", "blimp_eval", "blimp_test", "schedule" };
        for (ho_builtins) |name| {
            if (startsWith(name, prefix)) {
                results.append(self.allocator, .{
                    .label = std.fmt.allocPrint(self.allocator, "{s}()", .{name}) catch name,
                    .insert = std.fmt.allocPrint(self.allocator, "{s}(", .{name}) catch name,
                    .kind = .builtin,
                    .score = prefixScore(name, prefix) + 10,
                }) catch {};
            }
        }

        // 3. Keywords
        const keywords = [_][]const u8{
            "actor", "def", "fn", "for", "in", "do", "end", "on", "state",
            "become", "reply", "spawn", "self", "bubble", "try", "catch",
            "situation", "case", "orelse", "when", "bubbles", "true", "false", "nil",
            "test", "and", "or", "not",
        };
        for (keywords) |kw| {
            if (startsWith(kw, prefix) and prefix.len > 0) {
                results.append(self.allocator, .{
                    .label = kw,
                    .insert = kw,
                    .kind = .keyword,
                    .score = prefixScore(kw, prefix) + 20, // keywords rank last
                }) catch {};
            }
        }

        // 4. Actor templates (for spawn/struct notation)
        for (eval.registry.templates.items) |tmpl| {
            if (startsWith(tmpl.name, prefix)) {
                results.append(self.allocator, .{
                    .label = tmpl.name,
                    .insert = tmpl.name,
                    .kind = .actor_template,
                    .score = prefixScore(tmpl.name, prefix) + 5,
                }) catch {};
            }
        }

        // Sort by score (lower = better)
        std.mem.sort(Completion, results.items, {}, struct {
            fn lessThan(_: void, a: Completion, b: Completion) bool {
                return a.score < b.score;
            }
        }.lessThan);

        return results.items;
    }

    /// Create a completion for a variable, with type-aware argument filling.
    fn makeVarCompletion(self: *CompletionEngine, name: []const u8, val: *const Value, eval: *const Evaluator, prefix: []const u8) Completion {
        switch (val.*) {
            .closure => |c| {
                // Build label: "name(param: Type, param: Type) -> ReturnType"
                var label_buf = std.ArrayList(u8){ .items = &.{}, .capacity = 0 };
                var insert_buf = std.ArrayList(u8){ .items = &.{}, .capacity = 0 };

                label_buf.appendSlice(self.allocator, name) catch {};
                label_buf.append(self.allocator, '(') catch {};
                insert_buf.appendSlice(self.allocator, name) catch {};
                insert_buf.append(self.allocator, '(') catch {};

                for (c.params, 0..) |param, i| {
                    if (i > 0) {
                        label_buf.appendSlice(self.allocator, ", ") catch {};
                        insert_buf.appendSlice(self.allocator, ", ") catch {};
                    }
                    label_buf.appendSlice(self.allocator, param.name) catch {};
                    if (param.type_name) |t| {
                        label_buf.appendSlice(self.allocator, ": ") catch {};
                        label_buf.appendSlice(self.allocator, t) catch {};

                        // Type-aware auto-fill: find a variable in scope matching this type
                        const best = self.findBestMatch(t, eval);
                        if (best) |var_name| {
                            insert_buf.appendSlice(self.allocator, var_name) catch {};
                        } else {
                            insert_buf.appendSlice(self.allocator, param.name) catch {};
                        }
                    } else {
                        insert_buf.appendSlice(self.allocator, param.name) catch {};
                    }
                }

                label_buf.append(self.allocator, ')') catch {};
                insert_buf.append(self.allocator, ')') catch {};

                if (c.return_type) |rt| {
                    label_buf.appendSlice(self.allocator, " -> ") catch {};
                    label_buf.appendSlice(self.allocator, rt) catch {};
                }

                return .{
                    .label = label_buf.items,
                    .insert = insert_buf.items,
                    .kind = .function,
                    .score = prefixScore(name, prefix),
                };
            },
            else => {
                return .{
                    .label = std.fmt.allocPrint(self.allocator, "{s} = {s}", .{ name, val.typeName() }) catch name,
                    .insert = name,
                    .kind = .variable,
                    .score = prefixScore(name, prefix),
                };
            },
        }
    }

    /// Find the best variable in scope matching a type name.
    /// Returns the variable name or null if no match.
    fn findBestMatch(self: *CompletionEngine, type_name: []const u8, eval: *const Evaluator) ?[]const u8 {
        const bindings = eval.env.allBindings(self.allocator);

        for (bindings) |binding| {
            // Check if this variable's value matches the expected type
            const val = binding.val;
            if (std.mem.eql(u8, type_name, "Int") and val.* == .integer) return binding.name;
            if (std.mem.eql(u8, type_name, "Float") and val.* == .float) return binding.name;
            if (std.mem.eql(u8, type_name, "String") and val.* == .string) return binding.name;
            if (std.mem.eql(u8, type_name, "Bool") and val.* == .boolean) return binding.name;
            if (std.mem.eql(u8, type_name, "Atom") and val.* == .atom) return binding.name;
            if (std.mem.eql(u8, type_name, "List") and val.* == .list) return binding.name;
            if (std.mem.eql(u8, type_name, "Map") and val.* == .map) return binding.name;
            // Actor type: check ref's type_name
            if (val.* == .actor_ref) {
                if (std.mem.eql(u8, val.actor_ref.type_name, type_name)) return binding.name;
            }
            // List type: [Int] etc
            if (type_name.len > 2 and type_name[0] == '[' and val.* == .list) return binding.name;
        }

        return null;
    }

    /// Score a name against a prefix (lower = better match).
    fn prefixScore(name: []const u8, prefix: []const u8) u32 {
        if (prefix.len == 0) return 100;
        if (std.mem.eql(u8, name, prefix)) return 0; // exact match
        if (startsWith(name, prefix)) return @intCast(name.len - prefix.len); // prefix match, shorter = better
        return 50;
    }

    fn startsWith(haystack: []const u8, needle: []const u8) bool {
        if (needle.len > haystack.len) return false;
        return std.mem.eql(u8, haystack[0..needle.len], needle);
    }
};

// ============================================================
// Tests
// ============================================================

test "basic prefix completion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var engine = CompletionEngine.init(alloc);
    var eval = Evaluator.init(alloc);

    // Define some variables
    const int_val = try alloc.create(Value);
    int_val.* = Value{ .integer = 42 };
    eval.env.define("counter", int_val);

    const str_val = try alloc.create(Value);
    str_val.* = Value{ .string = "hello" };
    eval.env.define("count_stuff", str_val);

    const completions = engine.complete("count", &eval);
    try std.testing.expect(completions.len >= 2);
}

