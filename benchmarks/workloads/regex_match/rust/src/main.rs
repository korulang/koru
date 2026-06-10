use regex::Regex;
use std::env;

fn main() {
    let n: u64 = env::args()
        .nth(1)
        .and_then(|s| s.parse().ok())
        .unwrap_or(3_000_000);

    let email = Regex::new(r"^[a-z]+@[a-z]+$").unwrap();
    let number = Regex::new(r"^[0-9]+$").unwrap();
    let inputs = ["foo@bar", "12345", "hello world!"];

    let (mut ce, mut cn, mut cx) = (0u64, 0u64, 0u64);
    for i in 0..n {
        let s = inputs[(i % 3) as usize];
        if email.is_match(s) {
            ce += 1;
        } else if number.is_match(s) {
            cn += 1;
        } else {
            cx += 1;
        }
    }
    println!("email = {} number = {} none = {}", ce, cn, cx);
}
