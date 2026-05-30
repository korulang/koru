// chain_dynamic.mjs — the SAME depth-3 nested event-dispatch chain as
// chain.kjs, written the way a JS developer idiomatically writes nested
// event dispatch: Node's EventEmitter, with a dynamic (string-keyed,
// listener-registry) dispatch at every hop.
//
// Structure mirrors the Koru chain exactly:
//   outer fires its "v" effect per element  -> each fire triggers a mid dispatch
//   mid   fires its "v" effect per element  -> each fire triggers a leaf dispatch
//   leaf  fires its "v" effect per element  -> each fire triggers an inc dispatch
//   inc   bumps the module-level counter
// Result: counter === n^3, identical to the static version.
//
// This is a FAIR representation, not a strawman: each level is a real
// EventEmitter whose per-element step ("v") goes through emit()/on() —
// exactly the per-hop dynamic dispatch the structural argument is about.

import { EventEmitter } from "node:events";

const n = parseInt(process.argv[2] || "10");
let counter = 0;

// inc level: a plain event whose handler bumps the counter.
const inc = new EventEmitter();
inc.on("fire", () => {
  counter++;
});

// leaf level: an effect-bearing event. Its handler loops n times, firing the
// "v" effect each iteration; each "v" dispatches an inc.
const leaf = new EventEmitter();
leaf.on("v", () => {
  inc.emit("fire");
});
leaf.on("run", (m) => {
  for (let i = 0; i < m; i++) leaf.emit("v", i);
});

// mid level: effect-bearing. Each "v" dispatches a leaf run.
const mid = new EventEmitter();
mid.on("v", () => {
  leaf.emit("run", n);
});
mid.on("run", (m) => {
  for (let i = 0; i < m; i++) mid.emit("v", i);
});

// outer level: effect-bearing. Each "v" dispatches a mid run.
const outer = new EventEmitter();
outer.on("v", () => {
  mid.emit("run", n);
});
outer.on("run", (m) => {
  for (let i = 0; i < m; i++) outer.emit("v", i);
});

// report level: a plain event that prints the counter.
const report = new EventEmitter();
report.on("fire", () => {
  console.log("counter = " + counter);
});

// Drive the chain.
outer.emit("run", n);
report.emit("fire");
