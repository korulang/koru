function* rangeGen(n) {
    for (let i = 0n; i < n; i++) yield i;
}

const MASK = (1n << 64n) - 1n;
const n = BigInt(process.argv[2]);
let s = 0n;
for (const v of rangeGen(n)) {
    s = (s + v) & MASK;
}
console.log(`sum = ${s}`);
