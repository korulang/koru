use regex::Regex;
use std::env;

fn main() {
    let n: u64 = env::args()
        .nth(1)
        .and_then(|s| s.parse().ok())
        .unwrap_or(3_000_000);

    // Named captures, anchored full-match — same shape as the Koru pattern.
    let re = Regex::new(r"^(?<l>[0-9]+)x(?<w>[0-9]+)x(?<h>[0-9]+)$").unwrap();
    let inputs = ["2x3x4", "20x3x11", "hello world!"];

    let (mut matched, mut none, mut total) = (0u64, 0u64, 0u64);
    for i in 0..n {
        let s = inputs[(i % 3) as usize];
        if let Some(caps) = re.captures(s) {
            let l: u64 = caps.name("l").unwrap().as_str().parse().unwrap();
            let w: u64 = caps.name("w").unwrap().as_str().parse().unwrap();
            let h: u64 = caps.name("h").unwrap().as_str().parse().unwrap();
            total += l * w * h;
            matched += 1;
        } else {
            none += 1;
        }
    }
    println!("matched = {} none = {} total = {}", matched, none, total);
}
