fn abs_val(x: i64) -> i64 {
    if x >= 0 { x } else { -x }
}
fn manhattan(x1: i64, y1: i64, x2: i64, y2: i64) -> i64 {
    abs_val(x1 - x2) + abs_val(y1 - y2)
}
fn grid_row(y: i64, cols: i64, qx: i64, qy: i64) -> i64 {
    if cols == 0 { return 0; }
    manhattan(cols, y, qx, qy) + grid_row(y, cols - 1, qx, qy)
}
fn grid_distances(n: i64, qx: i64, qy: i64) -> i64 {
    if n == 0 { return 0; }
    grid_row(n, n, qx, qy) + grid_distances(n - 1, qx, qy)
}
fn main() {
    println!("{}", grid_distances(1000, 500, 500));
}
