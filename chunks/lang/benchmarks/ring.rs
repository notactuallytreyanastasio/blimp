use std::time::Instant;
use std::sync::mpsc;
use std::thread;

fn main() {
    let start = Instant::now();

    // Create 10 "actor" channels
    let mut senders = Vec::new();
    let mut receivers = Vec::new();

    for _ in 0..10 {
        let (tx, rx) = mpsc::channel::<(i64, mpsc::Sender<i64>)>();
        senders.push(tx);

        thread::spawn(move || {
            loop {
                match rx.recv() {
                    Ok((token, reply_tx)) => {
                        reply_tx.send(token + 1).ok();
                    }
                    Err(_) => break,
                }
            }
        });
    }

    // Pass token around 100 times
    let mut total: i64 = 0;
    for _ in 0..100 {
        for sender in &senders {
            let (reply_tx, reply_rx) = mpsc::channel();
            sender.send((total, reply_tx)).unwrap();
            total = reply_rx.recv().unwrap();
        }
    }

    let elapsed = start.elapsed();
    println!("{} ({:.1}ms)", total, elapsed.as_secs_f64() * 1000.0);
}
