// Localize the per-element overhead of the Koru effect-handler lowering.
// Strips away the resource + union noise; just the inner loop, four ways:
//   1. flat        - idiomatic inline (the body written directly)
//   2. call_box    - H.step(i), handler closes over a reassigned `let acc` (boxed context cell)
//   3. call_field  - H.step(i), handler accumulates into H.acc (object property, no box)
//   4. inlined     - what a static-handler-aware emitter emits: body inlined (== flat)
//
// In Koru the handler is statically known, so an emitter is FREE to pick (4).
// The naive emitter picks (2). This shows the cost of that choice.

const N = 5_000_000;
const REPS = 15;
const WARMUP = 6;

const body = (acc, i) => (acc + ((i * i) ^ (i + 1))) | 0;

function flat(n) {
  let acc = 0;
  for (let i = 0; i < n; i++) acc = body(acc, i);
  return acc;
}

function call_box(n) {
  let acc = 0;
  const H = { step(v) { acc = body(acc, v); } };
  for (let i = 0; i < n; i++) H.step(i);
  return acc;
}

function call_field(n) {
  const H = { acc: 0, step(v) { this.acc = body(this.acc, v); } };
  for (let i = 0; i < n; i++) H.step(i);
  return H.acc;
}

function inlined(n) {
  // static-handler emitter: the `step` body is spliced at the call site
  let acc = 0;
  for (let i = 0; i < n; i++) acc = (acc + ((i * i) ^ (i + 1))) | 0;
  return acc;
}

function median(xs) {
  const s = [...xs].sort((a, b) => a - b);
  const m = s.length >> 1;
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
}

function run(label, fn) {
  for (let i = 0; i < WARMUP; i++) fn(N);
  const samples = [];
  let out;
  for (let i = 0; i < REPS; i++) {
    const t0 = process.hrtime.bigint();
    out = fn(N);
    samples.push(Number(process.hrtime.bigint() - t0));
  }
  const med = median(samples);
  return { label, nsPerEl: med / N, ms: med / 1e6, out };
}

const variants = [flat, call_box, call_field, inlined].map((f) => run(f.name.padEnd(10), f));
const base = variants[0].nsPerEl;
console.log(`N=${N.toLocaleString()}, median of ${REPS}\n`);
const ref = variants[0].out;
for (const v of variants) {
  const parity = v.out === ref ? 'OK ' : 'BAD';
  console.log(`  ${v.label} ${v.nsPerEl.toFixed(3)} ns/el  (${v.ms.toFixed(2)} ms)  ${(v.nsPerEl / base).toFixed(2)}x  parity:${parity}`);
}
