// Rust Baseline: Producer/Consumer with Crossbeam Channels
//
// Tests idiomatic Rust concurrency:
// - Bounded channel (1024 capacity, like MPMC ring and Go channels)
// - Threads (2 threads: producer + consumer)
// - Channel send/receive (10M messages)
// - Zero-cost abstractions (no runtime overhead)
// - Data integrity (checksum validation)
//
// Uses crossbeam for fair comparison:
// - Bounded channels (matching Go's buffered channels)
// - Lock-free implementation (matching Zig's MPMC ring)
// - No async runtime overhead (matching Zig's approach)
//
// This is how you'd actually write concurrent Rust code with channels.

use crossbeam::channel::bounded;
use std::thread;

const MESSAGES: u64 = 10_000_000;
const BUFFER_SIZE: usize = 1024;

fn main() {
    // Bounded channel - like Go's buffered channel and Zig's MPMC ring
    let (tx, rx) = bounded(BUFFER_SIZE);

    // Producer thread - send 10M messages
    let producer = thread::spawn(move || {
        for i in 0..MESSAGES {
            tx.send(i).unwrap();
        }
        // Channel automatically closed when tx is dropped
    });

    // Consumer runs on MAIN THREAD (same as Zig and Koru!)
    let mut sum = 0u64;
    for msg in rx {
        sum += msg;
    }

    // Wait for producer to finish
    producer.join().unwrap();

    // Validate checksum (sum of 0 to N-1 = N*(N-1)/2)
    let expected = MESSAGES * (MESSAGES - 1) / 2;
    if sum == expected {
        println!(
            "✓ Rust: Validated {} messages (checksum: {})",
            MESSAGES, sum
        );
    } else {
        println!(
            "✗ Rust: CHECKSUM MISMATCH! got {}, expected {}",
            sum, expected
        );
    }
}
