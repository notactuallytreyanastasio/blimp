const std = @import("std");
fn absVal(x: i64) i64 {
    return if (x >= 0) x else -x;
}
fn manhattan(x1: i64, y1: i64, x2: i64, y2: i64) i64 {
    return absVal(x1 - x2) + absVal(y1 - y2);
}
fn gridRow(y: i64, cols: i64, qx: i64, qy: i64) i64 {
    if (cols == 0) return 0;
    return manhattan(cols, y, qx, qy) + gridRow(y, cols - 1, qx, qy);
}
fn gridDistances(n: i64, qx: i64, qy: i64) i64 {
    if (n == 0) return 0;
    return gridRow(n, n, qx, qy) + gridDistances(n - 1, qx, qy);
}
pub fn main() void {
    std.debug.print("{d}\n", .{gridDistances(1000, 500, 500)});
}
