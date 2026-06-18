// register_machine — naive Rust baseline (the parity target).
// Same register machine as the Koru side: 7 `inc a` instructions, run N times.
// Arrays are borrowed by reference; the inner step is a plain loop (the natural
// way to write it). This is the "by-reference, no per-call payload copy" shape
// the Koru threaded-recursion idiom should be able to match.

fn run(mut pc: i64, mut a: i64, b: i64, ops: &[i64; 8], regs: &[i64; 8], offs: &[i64; 8], n: i64) -> i64 {
    // Mirror the Koru decode arithmetic exactly so both sides do equal work.
    while pc < n && pc >= 0 {
        let o = ops[pc as usize];
        let rg = regs[pc as usize];
        let of = offs[pc as usize];
        let rv = a * (1 - rg) + b * rg;
        let nrv = (rv / 2) * ((o == 0) as i64)
            + rv * 3 * ((o == 1) as i64)
            + (rv + 1) * ((o == 2) as i64)
            + rv * ((o >= 3) as i64);
        let sa = ((o <= 2) as i64) * (1 - rg);
        let tj = ((o == 3) as i64)
            + ((o == 4) as i64) * ((rv % 2 == 0) as i64)
            + ((o == 5) as i64) * ((rv == 1) as i64);
        let na = a * (1 - sa) + nrv * sa;
        let np = pc + of * tj + (1 - tj);
        a = na;
        pc = np;
    }
    a
}

fn main() {
    let n: u64 = std::env::args()
        .nth(1)
        .and_then(|s| s.parse().ok())
        .unwrap_or(20_000_000);

    let ops: [i64; 8] = [2, 2, 2, 2, 2, 2, 2, 0];
    let regs: [i64; 8] = [0, 0, 0, 0, 0, 0, 0, 0];
    let offs: [i64; 8] = [0, 0, 0, 0, 0, 0, 0, 0];

    let mut total: i64 = 0;
    let mut i: u64 = 0;
    while i < n {
        total += run(0, (i % 2) as i64, 0, &ops, &regs, &offs, 7);
        i += 1;
    }
    println!("total = {}", total);
}
