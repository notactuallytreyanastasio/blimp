fn tree_build(depth: i64) -> i64 {
    if depth == 0 { return 1; }
    let left = tree_build(depth - 1);
    let right = tree_build(depth - 1);
    left + right + 1
}
fn main() {
    println!("{}", tree_build(25));
}
