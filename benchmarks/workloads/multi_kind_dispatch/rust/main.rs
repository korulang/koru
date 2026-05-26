use std::env;

enum Ev { Tick, Tock }

fn main() {
    let n: u64 = env::args().nth(1).unwrap().parse().unwrap();
    let (ticks, tocks) = (0..n)
        .map(|i| if i % 2 == 0 { Ev::Tick } else { Ev::Tock })
        .fold((0u64, 0u64), |(t, k), e| match e {
            Ev::Tick => (t + 1, k),
            Ev::Tock => (t, k + 1),
        });
    println!("ticks = {} tocks = {}", ticks, tocks);
}
