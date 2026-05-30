// Bench harness: race Koru-lowered style vs idiomatic JS on identical work.
// Verifies output parity first (a perf comparison of two different answers is
// meaningless), then warms up the JIT and takes multiple timed samples,
// reporting the median ns/element so the two are directly comparable.

import * as koru from './koru_style.mjs';
import * as idio from './idiomatic.mjs';

const N = 5_000_000;          // elements per flow invocation
const CHUNKS = [1, 16, 256];  // how often the terminal union allocates
const REPS = 12;              // timed samples per config
const WARMUP = 5;

function median(xs) {
  const s = [...xs].sort((a, b) => a - b);
  const m = s.length >> 1;
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
}

function time(fn, n, chunk) {
  const t0 = process.hrtime.bigint();
  const out = fn(n, chunk);
  const t1 = process.hrtime.bigint();
  return { ns: Number(t1 - t0), out };
}

function run(label, fn, n, chunk) {
  for (let i = 0; i < WARMUP; i++) fn(n, chunk);
  const samples = [];
  let out;
  for (let i = 0; i < REPS; i++) {
    const r = time(fn, n, chunk);
    samples.push(r.ns);
    out = r.out;
  }
  const med = median(samples);
  return { label, med, nsPerEl: med / n, out };
}

console.log(`N=${N.toLocaleString()} elements/flow, ${REPS} samples, median reported\n`);

for (const chunk of CHUNKS) {
  // parity check
  const ko = koru.flow0(N, chunk);
  const id = idio.flow0(N, chunk);
  const parity = ko === id ? 'OK' : `MISMATCH koru=${ko} idio=${id}`;

  const k = run('koru-lowered', koru.flow0, N, chunk);
  const i = run('idiomatic   ', idio.flow0, N, chunk);
  const ratio = k.med / i.med;

  console.log(`--- CHUNK=${chunk}  (terminal union allocs ~ N/${chunk})   parity: ${parity}`);
  console.log(`  idiomatic    : ${i.nsPerEl.toFixed(3)} ns/el   (${(i.med / 1e6).toFixed(2)} ms)`);
  console.log(`  koru-lowered : ${k.nsPerEl.toFixed(3)} ns/el   (${(k.med / 1e6).toFixed(2)} ms)`);
  console.log(`  koru / idiomatic = ${ratio.toFixed(3)}x  ${ratio <= 1.05 ? '(on par)' : ratio <= 1.5 ? '(modest overhead)' : '(significant overhead)'}\n`);
}
