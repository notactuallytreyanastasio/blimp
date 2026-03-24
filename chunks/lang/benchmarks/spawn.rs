use std::time::Instant;
use std::sync::mpsc;
use std::thread;

fn main() {
    let start = Instant::now();

    for _ in 0..100 {
        let (tx, rx) = mpsc::channel();
        let handle = thread::spawn(move || {
            // "Actor" receives increment message
            let mut count = 0i64;
            count += 1;
            tx.send(count).unwrap();
        });
        let _result = rx.recv().unwrap();
        handle.join().unwrap();
    }

    let elapsed = start.elapsed();
    println!("100 actors, 100 sends ({:.1}ms)", elapsed.as_secs_f64() * 1000.0);
}
