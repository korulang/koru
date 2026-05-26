function* rangeGen(n) {
    for (let i = 0n; i < n; i++) yield i;
}

const n = BigInt(process.argv[2]);
let a = 0n;
for (const v of rangeGen(n)) {
    a ^= v;
}
console.log(`xor = ${a}`);
