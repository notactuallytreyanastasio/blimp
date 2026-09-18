const std = @import("std");

/// The process's `Io`, set once by `main` before anything can reach a builtin.
///
/// zig 0.16 made I/O a capability: `std.Io.File.stdout()` still hands back a
/// file, but writing to it wants an `Io` that only `main` can build. A builtin
/// is a `fn (Allocator, []const *const Value)` and threading a third parameter
/// through every one of them -- most of which never touch I/O -- would say
/// less than this does.
///
/// Undefined until `install` runs. Nothing can call a builtin before then.
pub var io: std.Io = undefined;

pub fn install(value: std.Io) void {
    io = value;
}
