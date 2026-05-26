function* rangeGen(n) {
    for (let i = 0n; i < n; i++) yield i;
}

const MASK = (1n << 64n) - 1n;
const n = BigInt(process.argv[2]);
let acc = 0n;
for (const v of rangeGen(n)) {
    if ((v & 1n) === 0n) acc = (acc + v * v) & MASK;
}
console.log(`result = ${acc}`);
