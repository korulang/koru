function* ticker(n) {
    for (let i = 0n; i < n; i++) {
        if (i % 2n === 0n) yield ['tick', i];
        else yield ['tock', i];
    }
}

const n = BigInt(process.argv[2]);
let ticks = 0n;
let tocks = 0n;
for (const [kind, _v] of ticker(n)) {
    if (kind === 'tick') ticks++;
    else tocks++;
}
console.log(`ticks = ${ticks} tocks = ${tocks}`);
