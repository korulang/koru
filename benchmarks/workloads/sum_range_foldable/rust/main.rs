use std::env;

fn main() {
    let n: u64 = env::args().nth(1).unwrap().parse().unwrap();
    let s: u64 = (0..n).fold(0u64, |acc, i| acc.wrapping_add(i));
    println!("sum = {}", s);
}
