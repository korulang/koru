// "Endless chains of dynamic dispatch" — the compounding case.
//
// A pipeline of K stages. Each input event flows through all K stages; each
// stage does tiny work and forwards to the next. This is the shape of real JS:
// event -> emitter -> handler re-emits -> emitter -> ... (middleware, reactive
// operator chains, reducer+effect cascades).
//
//   JS dynamic:  each hop is `next.emit(...)` / a forwarded callback -> K dynamic
//                dispatches per event, none of which V8 can fuse across.
//   Koru static: each internal re-emit is a statically-resolved DIRECT call, so
//                the K-stage chain inlines into one fused function.
//
// We sweep K to show the gap widening with chain depth.

import { EventEmitter } from 'node:events';

const M = 2_000_000;     // input events
const DEPTHS = [1, 4, 8, 16];
const REPS = 9;
const WARMUP = 3;

// Per-stage work: mix the value forward so nothing is dead-code-eliminated.
const stageOp = (acc, v) => (acc + ((v ^ (v >>> 1)) & 7)) | 0;

// ---- JS dynamic: a chain of EventEmitters, each forwarding to the next ----
function viaEmitterChain(K) {
  const sink = { total: 0 };
  const ems = Array.from({ length: K }, () => new EventEmitter());
  for (let s = 0; s < K; s++) {
    const next = s + 1 < K ? ems[s + 1] : null;
    ems[s].on('ev', (v) => {
      const w = stageOp(0, v + s);
      if (next) next.emit('ev', w);
      else sink.total = (sink.total + w) | 0;
    });
  }
  const head = ems[0];
  for (let i = 0; i < M; i++) head.emit('ev', i);
  return sink.total;
}

// ---- Koru static: the chain as direct, statically-resolved calls ----
// A faithful emitter resolves each internal `! forward` to a direct call; the
// nested calls fuse. We build the fused function the way the emitter would,
// without dynamic lookup. (Loop-built closures still call directly, no emit.)
function viaStaticChain(K) {
  let total = 0;
  // build the chain of direct functions: stage s calls stage s+1
  let fn = (v) => { total = (total + v) | 0; }; // terminal sink
  for (let s = K - 1; s >= 0; s--) {
    const next = fn;
    const sidx = s;
    fn = (v) => { next(stageOp(0, v + sidx)); };
  }
  for (let i = 0; i < M; i++) fn(i);
  return total;
}

// ---- Koru static, fully fused: what inlining the whole chain yields ----
// When every hop is statically known, the K stages collapse into one loop body.
function viaFusedChain(K) {
  let total = 0;
  for (let i = 0; i < M; i++) {
    let v = i;
    for (let s = 0; s < K; s++) v = stageOp(0, v + s);
    total = (total + v) | 0;
  }
  return total;
}

function median(xs){const s=[...xs].sort((a,b)=>a-b);const m=s.length>>1;return s.length%2?s[m]:(s[m-1]+s[m])/2;}
function run(fn, K){
  for(let i=0;i<WARMUP;i++)fn(K);
  const s=[];let out;
  for(let i=0;i<REPS;i++){const t0=process.hrtime.bigint();out=fn(K);s.push(Number(process.hrtime.bigint()-t0));}
  return {nsPerHop: median(s)/(M*K), ms: median(s)/1e6, out};
}

console.log(`dispatch chain, M=${M.toLocaleString()} events, sweep depth K (ns per HOP)\n`);
console.log(`  K   emitter-chain   static-chain   fused-chain   parity   emitter/fused`);
for (const K of DEPTHS) {
  const e = run(viaEmitterChain, K);
  const s = run(viaStaticChain, K);
  const f = run(viaFusedChain, K);
  const parity = (e.out === s.out && s.out === f.out) ? 'OK ' : `BAD ${e.out}/${s.out}/${f.out}`;
  console.log(`  ${String(K).padStart(2)}   ${e.nsPerHop.toFixed(2).padStart(8)} ns   ${s.nsPerHop.toFixed(2).padStart(8)} ns   ${f.nsPerHop.toFixed(2).padStart(7)} ns   ${parity}   ${(e.nsPerHop/f.nsPerHop).toFixed(1)}x`);
}
console.log(`\n(ns per hop = total time / (events * depth); fused-chain shows what`);
console.log(` static resolution + inlining buys once the whole chain is known.)`);
