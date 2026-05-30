// run_sweep.mjs — depth-sweep benchmark driver.
// For each D in [1,2,4,8,16] (M fixed = 1_000_000):
//   - generate the three files (via gen_pipeline.mjs)
//   - compile the koru one with koruc --lang=js -> pipe_dD_koru.js
//   - PARITY: all three must print "counter = 1000000"
//   - time each (5 runs, median), subtract `node -e ""` baseline median
//   - ns/hop = (median_ms - baseline) * 1e6 / (M * (D+1))
// Prints a table: D, koru ns/hop, dynamic ns/hop, flat ns/hop, dyn/koru, koru/flat.

import { execFileSync } from "node:child_process";

const M = parseInt(process.env.M || "1000000");
const DEPTHS = [1, 2, 4, 8, 16];
const RUNS = parseInt(process.env.RUNS || "5");
const KORUC = "../zig-out/bin/koruc";

function median(xs) {
  const s = [...xs].sort((a, b) => a - b);
  const n = s.length;
  return n % 2 ? s[(n - 1) / 2] : (s[n / 2 - 1] + s[n / 2]) / 2;
}

// Time a `node <args>` invocation: returns wall ms (parent-measured).
function timeNode(args) {
  const t0 = process.hrtime.bigint();
  const out = execFileSync("node", args, { encoding: "utf8" });
  const t1 = process.hrtime.bigint();
  return { ms: Number(t1 - t0) / 1e6, out: out.trim() };
}

// Baseline: empty node process startup.
function baselineMedian() {
  const samples = [];
  for (let r = 0; r < RUNS; r++) samples.push(timeNode(["-e", ""]).ms);
  return median(samples);
}

function run(file, expectOut) {
  const samples = [];
  let lastOut = "";
  for (let r = 0; r < RUNS; r++) {
    const { ms, out } = timeNode([file, String(M)]);
    samples.push(ms);
    lastOut = out;
  }
  if (lastOut !== expectOut) {
    throw new Error(`PARITY FAIL: ${file} printed "${lastOut}", expected "${expectOut}"`);
  }
  return median(samples);
}

const expectOut = `counter = ${M}`;

console.error("measuring baseline (node -e '')...");
const baseline = baselineMedian();
console.error(`baseline median: ${baseline.toFixed(2)} ms\n`);

const rows = [];
for (const D of DEPTHS) {
  console.error(`=== D=${D} ===`);
  // generate
  execFileSync("node", ["gen_pipeline.mjs", String(D)], { stdio: "inherit" });
  // compile koru
  execFileSync(KORUC, ["--lang=js", `pipe_d${D}.kjs`], { stdio: "ignore" });
  execFileSync("cp", ["output_emitted.js", `pipe_d${D}_koru.js`]);

  const koruMs = run(`pipe_d${D}_koru.js`, expectOut);
  const dynMs = run(`pipe_d${D}_dynamic.mjs`, expectOut);
  const flatMs = run(`pipe_d${D}_flat.mjs`, expectOut);
  console.error(`  parity OK; medians (raw ms): koru=${koruMs.toFixed(1)} dyn=${dynMs.toFixed(1)} flat=${flatMs.toFixed(1)}`);

  const hops = M * (D + 1);
  const nsPerHop = (ms) => ((ms - baseline) * 1e6) / hops;
  const koruNs = nsPerHop(koruMs);
  const dynNs = nsPerHop(dynMs);
  const flatNs = nsPerHop(flatMs);
  rows.push({ D, koruNs, dynNs, flatNs, dynKoru: dynNs / koruNs, koruFlat: koruNs / flatNs });
}

const f = (x, w = 7) => x.toFixed(2).padStart(w);
console.log(`\nBaseline (node -e ""): ${baseline.toFixed(2)} ms   M=${M}   runs=${RUNS} (median)`);
console.log(`ns/hop (hops = M*(D+1)), startup-subtracted\n`);
console.log("  D | koru ns/hop | dyn ns/hop | flat ns/hop | dyn/koru | koru/flat");
console.log("----+-------------+------------+-------------+----------+----------");
for (const r of rows) {
  console.log(
    ` ${String(r.D).padStart(2)} | ${f(r.koruNs, 11)} | ${f(r.dynNs, 10)} | ${f(r.flatNs, 11)} | ${f(r.dynKoru, 8)} | ${f(r.koruFlat, 8)}`
  );
}
