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
//   6. koru EMITTED (yesterday)  — what js_emitter.zig produced before the
//                                  plain-event inline optimization:
//                                  `main_module.<ev>_event.handler({...})` on
//                                  every dispatch, with arg-object allocation
//   7. koru EMITTED (today)      — what js_emitter.zig produces NOW: handler
//                                  bodies inlined at dispatch site, no object
//                                  lookup, no arg-allocation. Also no events[]
//                                  read — koru fuses producer + consumer, so
//                                  payloads are computed from `i` inline.
//
// (5) is the theoretical ceiling for object-free static dispatch in JS reading
// pre-allocated events. (6) is the cost of the closure-path lowering koru USED
// to emit. (7) is what koru emits today — and because koru can fuse producer
// and consumer at compile time, it can SKIP the events[] indirection entirely
// (the producer's loop and the dispatch are in the same function). That's a
// structural win JS can't match without losing the dynamism it's paying for.

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

// ---------- 6. koru EMITTED (yesterday) ----------
// What js_emitter.zig produced before the plain-event inline optimization:
// `main_module.<event>_event.handler({...})` on every dispatch, with arg-
// object allocation. Reads from events[] for the same reason 1-5 do —
// pre-allocated stream simulating an external event source.
function viaKoruEmittedYesterday() {
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

// ---------- 7. koru EMITTED (today) ----------
// Faithful copy of what js_emitter.zig produces NOW for 140_011 after the
// plain-event inline optimization landed: handler bodies spliced in place at
// each dispatch site, no `main_module.<ev>_event.handler({...})` call, no
// arg-object allocation. ALSO no events[] read — koru fuses producer and
// consumer at compile time so payload values are computed from `i` inline,
// matching what flow0 of output_emitted.js does.
function viaKoruEmittedToday() {
  const c = freshCounts();
  for (let i = 0; i < N; i++) {
    const m = i % 64;
    if (m === 63) {
      const w = 80 + (i & 31);
      { const width = w; c.resizes++; c.width_sum += width; }
    } else if (m === 31) {
      const f = i;
      { const id = f; c.focus++; c.focus_xor ^= id; }
    } else {
      const ch_local = (i % 97 === 0) ? 113 : 97 + (i % 26);
      { const ch = ch_local; c.keys++; if (ch === 113) c.quits++; }
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
  ['1. EventEmitter (idiom)        ', viaEmitter],
  ['2. listener-map (hand)         ', viaListenerMap],
  ['3. koru switch+call            ', viaSwitchCall],
  ['4. koru str-switch+inline      ', viaSwitchInline],
  ['5. koru int-switch+inline      ', viaIntSwitchInline],
  ['6. koru EMITTED (yesterday)    ', viaKoruEmittedYesterday],
  ['7. koru EMITTED (today)        ', viaKoruEmittedToday],
].map(([l, f]) => run(l, f));

const key = (c) => `${c.keys}/${c.resizes}/${c.focus}/${c.quits}/${c.width_sum}/${c.focus_xor}`;
const ref = key(rows[0].out);
for (const r of rows) {
  const parity = key(r.out) === ref ? 'OK ' : `BAD(${key(r.out)})`;
  console.log(`  ${r.label} ${r.nsPerEv.toFixed(2).padStart(6)} ns/event  (${r.ms.toFixed(0).padStart(4)} ms)  parity:${parity}`);
}
const em = rows[0].nsPerEv;
const ko_ideal = rows[4].nsPerEv;
const ko_yesterday = rows[5].nsPerEv;
const ko_today = rows[6].nsPerEv;
console.log(`\n  EventEmitter / koru TODAY          = ${(em / ko_today).toFixed(2)}x  (real-world structural win, post-inline)`);
console.log(`  EventEmitter / koru YESTERDAY      = ${(em / ko_yesterday).toFixed(2)}x  (pre-inline baseline)`);
console.log(`  koru YESTERDAY / koru TODAY        = ${(ko_yesterday / ko_today).toFixed(2)}x  (what inline-plain-event bought us)`);
console.log(`  koru TODAY / koru int-static       = ${(ko_today / ko_ideal).toFixed(2)}x  (remaining tax vs ideal; <1 if producer-fusion wins)`);
