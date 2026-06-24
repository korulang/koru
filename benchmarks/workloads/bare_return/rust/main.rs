use std::env;

#[inline]
fn mix(x: u64) -> u64 {
    x.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407)
}

fn main() {
    let n: u64 = env::args().nth(1).and_then(|s| s.parse().ok()).unwrap_or(1_000_000);
    let mut acc: u64 = 1;
    for _ in 0..n {
        acc = mix(acc);
    }
    println!("result = {}", acc);
}
