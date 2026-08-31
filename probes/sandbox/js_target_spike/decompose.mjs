// Split the benchmark's JS cost into its two independent taxes:
//   - the generator/yield protocol  (the event-driven model -> Koru effect branches kill this)
//   - BigInt 64-bit arithmetic      (a JS data-model limit -> Koru->JS would INHERIT this)
//
// Workload = sum_range_xor: acc ^= i over 0..n.
// NOTE: `^` on a JS Number truncates to int32, so the Number variants compute a
// DIFFERENT (wrong-for-u64) answer — they're shown only to price the yield protocol
// independent of BigInt. The BigInt variants are the 64-bit-correct ones and match
// the committed benchmark.

const N = 100_000_000; // 1e8
const REPS = 5;
const WARMUP = 2;

function* rangeGen(n) { for (let i = 0; i < n; i++) yield i; }
function* rangeGenBig(n) { for (let i = 0n; i < n; i++) yield i; }

function flat_num(n)  { let a = 0;  for (let i = 0; i < n; i++)        a ^= i; return a; }
function gen_num(n)   { let a = 0;  for (const v of rangeGen(n))       a ^= v; return a; }
function flat_big(n)  { let a = 0n; for (let i = 0n; i < BigInt(n); i++) a ^= i; return a; }
function gen_big(n)   { let a = 0n; for (const v of rangeGenBig(BigInt(n))) a ^= v; return a; } // == committed bench

function median(xs){const s=[...xs].sort((a,b)=>a-b);const m=s.length>>1;return s.length%2?s[m]:(s[m-1]+s[m])/2;}
function run(label, fn){
  for(let i=0;i<WARMUP;i++)fn(N);
  const s=[];let out;
  for(let i=0;i<REPS;i++){const t0=process.hrtime.bigint();out=fn(N);s.push(Number(process.hrtime.bigint()-t0));}
  return {label,nsPerEl:median(s)/N,ms:median(s)/1e6,out:String(out)};
}

console.log(`sum_range_xor, N=${N.toLocaleString()}, median of ${REPS}\n`);
const rows = [
  run('flat  Number (32-bit, wrong answer)', flat_num),
  run('gen   Number (32-bit, wrong answer)', gen_num),
  run('flat  BigInt (64-bit correct)      ', flat_big),
  run('gen   BigInt (64-bit) == committed  ', gen_big),
];
for (const r of rows) console.log(`  ${r.label}  ${r.nsPerEl.toFixed(2)} ns/el  (${r.ms.toFixed(1)} ms)  -> ${r.out}`);

console.log('\nDecomposition:');
const [fn_, gn, fb, gb] = rows.map(r=>r.nsPerEl);
console.log(`  yield tax  (Number): gen-flat = ${(gn-fn_).toFixed(2)} ns/el`);
console.log(`  yield tax  (BigInt): gen-flat = ${(gb-fb).toFixed(2)} ns/el`);
console.log(`  BigInt tax (flat)  : big-num  = ${(fb-fn_).toFixed(2)} ns/el`);
console.log(`  Koru->Zig measured : 0.345 ns/el (results CSV, n=1e9)`);
