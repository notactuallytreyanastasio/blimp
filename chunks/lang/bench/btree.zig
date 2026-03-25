const std = @import("std");
fn treeBuild(depth: i64) i64 {
    if (depth == 0) return 1;
    const left = treeBuild(depth - 1);
    const right = treeBuild(depth - 1);
    return left + right + 1;
}
pub fn main() void {
    std.debug.print("{d}\n", .{treeBuild(25)});
}
