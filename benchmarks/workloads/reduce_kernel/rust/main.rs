use std::env;

fn main() {
    let n: u64 = env::args().nth(1).and_then(|s| s.parse().ok()).unwrap_or(1);
    let m: [f64; 64] = std::array::from_fn(|i| (i as f64 * 999.0 + 1.0) + 0.5);
    let mut total = 0.0f64;
    let mut count = 0u64;
    for _ in 0..n {
        for i in 0..64 {
            total += m[i];
            count += 1;
        }
    }
    println!("total={:.0} count={}", total, count);
}
