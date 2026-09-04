// Blimp Language - Core library
//
// This is the root module that re-exports all parser components.
// Tests from all modules are pulled in via @import.

pub const Token = @import("token.zig").Token;
pub const Lexer = @import("lexer.zig").Lexer;
pub const ast = @import("ast.zig");
pub const Parser = @import("parser.zig").Parser;
pub const types = @import("types.zig");
pub const Checker = @import("checker.zig").Checker;
pub const introspect = @import("introspect.zig");
pub const Value = @import("value.zig").Value;
pub const Environment = @import("env.zig").Environment;
pub const builtins = @import("builtins.zig");
pub const Evaluator = @import("eval.zig").Evaluator;
pub const errors = @import("errors.zig");
pub const Registry = @import("registry.zig").Registry;
pub const CompletionEngine = @import("complete.zig").CompletionEngine;
pub const gc = @import("gc.zig");

test {
    // Pull in tests from all modules
    @import("std").testing.refAllDecls(@This());
}
