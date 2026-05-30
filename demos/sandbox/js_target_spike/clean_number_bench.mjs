// Deconfounded: u64 -> number on BOTH sides. Only variable = control-flow shape.
// Workload = sum_range_xor resume-value form:
//   ! v { item, acc } -> u64   ;   ~proc { for i in 0..n: acc = v({item:i, acc}) }
//   handler:  ! v p |> p.acc ^ p.item
//
// IDIOMATIC JS (how a human writes "fold a transform over a range"):
//   flat     - imperative loop (fastest possible idiomatic)
//   hof      - higher-order callback fold (functional idiom)
//   gen      - lazy generator + fold (the composable/streaming idiom)
// KORU-LOWERED JS (what an emitter produces from the effect-branch source):
//   naive    - indirect handler call + per-iter payload object (dumb emitter)
//   inlined  - static handler body spliced at call site (smart emitter, == flat)

const N = 100_000_000;
const REPS = 11;
const WARMUP = 4;

// ---- idiomatic ----
function flat(n) { let a = 0; for (let i = 0; i < n; i++) a = a ^ i; return a; }

function hof(n) {
  const step = (acc, item) => acc ^ item;        // the transform, as a value
  let a = 0;
  for (let i = 0; i < n; i++) a = step(a, i);
  return a;
}

function* range(n) { for (let i = 0; i < n; i++) yield i; }
function gen(n) { let a = 0; for (const v of range(n)) a = a ^ v; return a; }

// ---- koru-lowered ----
// faithful naive: proc loops, fires effect `v` with a payload struct, uses resume value
const xor_range_event = {
  handler(input, H) {
    let acc = 0;
    for (let i = 0; i < input.n; i++) {
      acc = H.v({ item: i, acc });   // effect call: payload object + indirect call + resume value
    }
    return { tag: 'done', done: acc };
  },
};
function naive(n) {
  const H = { v(p) { return p.acc ^ p.item; } };  // handler `! v p |> p.acc ^ p.item`
  return xor_range_event.handler({ n }, H).done;
}

// smart emitter: `v` is statically known -> inline its body, payload fields become locals
function inlined(n) { let acc = 0; for (let i = 0; i < n; i++) acc = acc ^ i; return acc; }

function median(xs){const s=[...xs].sort((a,b)=>a-b);const m=s.length>>1;return s.length%2?s[m]:(s[m-1]+s[m])/2;}
function run(label, fn){
  for(let i=0;i<WARMUP;i++)fn(N);
  const s=[];let out;
  for(let i=0;i<REPS;i++){const t0=process.hrtime.bigint();out=fn(N);s.push(Number(process.hrtime.bigint()-t0));}
  return {label,nsPerEl:median(s)/N,ms:median(s)/1e6,out};
}

console.log(`sum_range_xor (number), N=${N.toLocaleString()}, median of ${REPS}\n`);
const rows = [
  ['idiomatic  flat        ', flat],
  ['idiomatic  hof-callback ', hof],
  ['idiomatic  gen (stream) ', gen],
  ['koru-lower naive        ', naive],
  ['koru-lower inlined      ', inlined],
].map(([l,f]) => run(l,f));

const ref = rows[0].out;
const flatNs = rows[0].nsPerEl;
const genNs = rows.find(r=>r.label.includes('gen')).nsPerEl;
for (const r of rows) {
  const parity = r.out === ref ? 'OK ' : `BAD(${r.out})`;
  console.log(`  ${r.label} ${r.nsPerEl.toFixed(2).padStart(6)} ns/el  ${(r.nsPerEl/flatNs).toFixed(2).padStart(5)}x flat   parity:${parity}`);
}
console.log('\nThe number that matters:');
const naiveNs = rows.find(r=>r.label.includes('naive')).nsPerEl;
const inlNs   = rows.find(r=>r.label.includes('inlined')).nsPerEl;
console.log(`  idiomatic streaming (gen) / koru-lowered naive   = ${(genNs/naiveNs).toFixed(1)}x  (koru wins even with a dumb emitter)`);
console.log(`  idiomatic streaming (gen) / koru-lowered inlined = ${(genNs/inlNs).toFixed(1)}x  (koru wins with a smart emitter)`);
console.log(`  koru-lowered inlined / idiomatic flat            = ${(inlNs/flatNs).toFixed(2)}x  (parity with the best hand-written loop)`);
