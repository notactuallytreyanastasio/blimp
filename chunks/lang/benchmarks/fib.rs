use std::time::Instant;

fn fib(n: i64) -> i64 {
    if n <= 1 { return n; }
    fib(n - 1) + fib(n - 2)
}

fn main() {
    let start = Instant::now();
    let result = fib(30);
    let elapsed = start.elapsed();
    println!("{} ({:.1}ms)", result, elapsed.as_secs_f64() * 1000.0);
}
