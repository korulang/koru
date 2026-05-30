// vaxis-shaped event dispatch — what does the koru-target lower to vs
// idiomatic JS?
//
// A producer yields a stream of terminal events (key / resize / focus_in).
// The consumer handles each by kind. The handler work mirrors
// tests/regression/100_MODULE_SYSTEM/140_FILE_LAYOUT/140_011_vaxis_pump_realistic:
//   key:    keys++; if (ch === 113) quits++
//   resize: resizes++; width_sum += width
//   focus:  focus++; focus_xor ^= id
//
// SIX dispatch strategies, same shared event stream, same handler work,
// parity-checked, median of REPS samples:
//   1. EventEmitter             — Node's `events` module (the idiom)
//   2. listener-map             — hand-rolled { type: [fns] } registry
//   3. koru switch+call         — static switch -> direct handler call
//   4. koru str-switch+inline   — static switch on string tag, bodies inlined
//   5. koru int-switch+inline   — static switch on integer tag, bodies inlined
//   6. koru EMITTED (real)      — faithful copy of what js_emitter.zig produces
//                                 for 140_011: `main_module.<ev>_event.handler({...})`
//                                 with per-dispatch arg-object allocation
//
// (5) is the theoretical ceiling for object-free static dispatch in JS.
// (6) is what koru actually emits today — the gap between 5 and 6 is the
// per-dispatch object-method indirection + arg-object allocation cost koru
// pays for staying source-faithful to the Koru handler shape.

import { EventEmitter } from 'node:events';

const N = 5_000_000;
const REPS = 11;
const WARMUP = 4;

// --- build one shared event stream OUTSIDE timing (deterministic, no RNG) ---
// vaxis-shaped mix matching the 140_011 pump's i % 64 dispatch.
const events = new Array(N);
for (let i = 0; i < N; i++) {
  const m = i % 64;
  // `k` is the integer tag (0=key, 1=resize, 2=focus_in). `type` is the string
  // tag idiomatic hand-written JS dispatches on.
  if (m === 63)      events[i] = { type: 'resize',   k: 1, width: 80 + (i & 31) };
  else if (m === 31) events[i] = { type: 'focus_in', k: 2, id: i };
  else               events[i] = { type: 'key',      k: 0, ch: (i % 97 === 0) ? 113 /* 'q' */ : 97 + (i % 26) };
}

// shared "handler work" — six fields, mirrors 140_011's per-host module state
function freshCounts() {
  return { keys: 0, resizes: 0, focus: 0, quits: 0, width_sum: 0, focus_xor: 0 };
}

// ---------- 1. EventEmitter ----------
function viaEmitter() {
  const c = freshCounts();
  const em = new EventEmitter();
  em.on('key',      (e) => { c.keys++; if (e.ch === 113) c.quits++; });
  em.on('resize',   (e) => { c.resizes++; c.width_sum += e.width; });
  em.on('focus_in', (e) => { c.focus++; c.focus_xor ^= e.id; });
  for (let i = 0; i < N; i++) { const e = events[i]; em.emit(e.type, e); }
  return c;
}

// ---------- 2. hand-rolled listener map ----------
function viaListenerMap() {
  const c = freshCounts();
  const listeners = {
    key:      [(e) => { c.keys++; if (e.ch === 113) c.quits++; }],
    resize:   [(e) => { c.resizes++; c.width_sum += e.width; }],
    focus_in: [(e) => { c.focus++; c.focus_xor ^= e.id; }],
  };
  for (let i = 0; i < N; i++) {
    const e = events[i];
    const ls = listeners[e.type];
    for (let j = 0; j < ls.length; j++) ls[j](e);
  }
  return c;
}

// ---------- 3. koru-lowered: static switch -> direct handler call ----------
function viaSwitchCall() {
  const c = freshCounts();
  const onKey    = (e) => { c.keys++; if (e.ch === 113) c.quits++; };
  const onResize = (e) => { c.resizes++; c.width_sum += e.width; };
  const onFocus  = (e) => { c.focus++; c.focus_xor ^= e.id; };
  for (let i = 0; i < N; i++) {
    const e = events[i];
    switch (e.type) {
      case 'key':      onKey(e); break;
      case 'resize':   onResize(e); break;
      case 'focus_in': onFocus(e); break;
    }
  }
  return c;
}

// ---------- 4. koru-lowered: string-switch, handler bodies INLINED ----------
function viaSwitchInline() {
  const c = freshCounts();
  for (let i = 0; i < N; i++) {
    const e = events[i];
    switch (e.type) {
      case 'key':      c.keys++; if (e.ch === 113) c.quits++; break;
      case 'resize':   c.resizes++; c.width_sum += e.width; break;
      case 'focus_in': c.focus++; c.focus_xor ^= e.id; break;
    }
  }
  return c;
}

// ---------- 5. koru-lowered: INTEGER-tag switch, bodies INLINED ----------
function viaIntSwitchInline() {
  const c = freshCounts();
  for (let i = 0; i < N; i++) {
    const e = events[i];
    switch (e.k) {
      case 0: c.keys++; if (e.ch === 113) c.quits++; break;
      case 1: c.resizes++; c.width_sum += e.width; break;
      case 2: c.focus++; c.focus_xor ^= e.id; break;
    }
  }
  return c;
}

// ---------- 6. koru EMITTED (real) ----------
// Faithful copy of what `js_emitter.zig` produces for 140_011 — same shape,
// same object indirection (`main_module.<event>_event.handler(...)`), same
// per-dispatch arg-object allocation (`{ width: w }`). Only difference from
// the actual output_emitted.js: we pull payload values from `events[i]`
// instead of computing them inline (the events array stands in for the
// external producer a real vaxis app would have).
function viaKoruEmitted() {
  const c = freshCounts();
  const main_module = {
    onKey_event:    { handler(input) { const ch = input.ch;    c.keys++; if (ch === 113) c.quits++; } },
    onResize_event: { handler(input) { const width = input.width; c.resizes++; c.width_sum += width; } },
    onFocus_event:  { handler(input) { const id = input.id;    c.focus++; c.focus_xor ^= id; } },
  };
  for (let i = 0; i < N; i++) {
    const e = events[i];
    if (e.k === 1) {
      { main_module.onResize_event.handler({ width: e.width }); }
    } else if (e.k === 2) {
      { main_module.onFocus_event.handler({ id: e.id }); }
    } else {
      { main_module.onKey_event.handler({ ch: e.ch }); }
    }
  }
  return c;
}

function median(xs) {
  const s = [...xs].sort((a, b) => a - b);
  const m = s.length >> 1;
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
}
function run(label, fn) {
  for (let i = 0; i < WARMUP; i++) fn();
  const s = []; let out;
  for (let i = 0; i < REPS; i++) {
    const t0 = process.hrtime.bigint();
    out = fn();
    s.push(Number(process.hrtime.bigint() - t0));
  }
  return { label, nsPerEv: median(s) / N, ms: median(s) / 1e6, out };
}

console.log(`vaxis-shaped event dispatch, N=${N.toLocaleString()} events, median of ${REPS}\n`);
const rows = [
  ['1. EventEmitter (idiom)     ', viaEmitter],
  ['2. listener-map (hand)      ', viaListenerMap],
  ['3. koru switch+call         ', viaSwitchCall],
  ['4. koru str-switch+inline   ', viaSwitchInline],
  ['5. koru int-switch+inline   ', viaIntSwitchInline],
  ['6. koru EMITTED (real)      ', viaKoruEmitted],
].map(([l, f]) => run(l, f));

const key = (c) => `${c.keys}/${c.resizes}/${c.focus}/${c.quits}/${c.width_sum}/${c.focus_xor}`;
const ref = key(rows[0].out);
for (const r of rows) {
  const parity = key(r.out) === ref ? 'OK ' : `BAD(${key(r.out)})`;
  console.log(`  ${r.label} ${r.nsPerEv.toFixed(2).padStart(6)} ns/event  (${r.ms.toFixed(0).padStart(4)} ms)  parity:${parity}`);
}
const em = rows[0].nsPerEv;
const ko_ideal = rows[4].nsPerEv;
const ko_real = rows[5].nsPerEv;
console.log(`\n  EventEmitter / koru EMITTED     = ${(em / ko_real).toFixed(2)}x  (real-world structural win)`);
console.log(`  EventEmitter / koru int-static  = ${(em / ko_ideal).toFixed(2)}x  (theoretical ceiling)`);
console.log(`  koru EMITTED / koru int-static  = ${(ko_real / ko_ideal).toFixed(2)}x  (object-indirection + arg-alloc tax)`);
