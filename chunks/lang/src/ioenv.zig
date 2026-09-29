const std = @import("std");

/// The process's `Io`, set once by `main` before anything can reach a builtin.
///
/// zig 0.16 made I/O a capability: `std.Io.File.stdout()` still hands back a
/// file, but writing to it wants an `Io` that only `main` can build. A builtin
/// is a `fn (Allocator, []const *const Value)` and threading a third parameter
/// through every one of them -- most of which never touch I/O -- would say
/// less than this does.
///
/// `std.Io.failing` until `install` runs, rather than `undefined`.
///
/// A unit test calls a builtin without going through `main`, so nothing
/// installs anything, and an undefined vtable is a segfault in libc rather
/// than a message: `zig build test` crashed inside `dirCreateFile` reading a
/// function pointer at address 0xd0. Failing answers an error instead, which
/// is what a builtin already knows how to report.
pub var io: std.Io = .failing;

pub fn install(value: std.Io) void {
    io = value;
}
