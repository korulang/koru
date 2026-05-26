use std::env;

fn main() {
    let n: u64 = env::args().nth(1).unwrap().parse().unwrap();
    let acc: u64 = (0..n)
        .filter(|i| i % 2 == 0)
        .map(|i| i.wrapping_mul(i))
        .fold(0u64, |a, x| a.wrapping_add(x));
    println!("result = {}", acc);
}
