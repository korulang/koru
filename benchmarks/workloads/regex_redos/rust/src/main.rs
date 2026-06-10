use regex::Regex;
use std::env;

fn main() {
    let n: usize = env::args()
        .nth(1)
        .and_then(|s| s.parse().ok())
        .unwrap_or(30);

    let re = Regex::new(r"^(a+)+b$").unwrap();
    let input = "a".repeat(n);

    println!("matched = {} len = {}", re.is_match(&input), n);
}
