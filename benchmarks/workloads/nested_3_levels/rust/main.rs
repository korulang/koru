use std::env;

fn main() {
    let n: u64 = env::args().nth(1).unwrap().parse().unwrap();
    let counter: u64 = (0..n)
        .flat_map(|_| (0..n).flat_map(move |_| (0..n)))
        .count() as u64;
    println!("counter = {}", counter);
}
