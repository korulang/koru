// bench_chain.mjs — race the REAL Koru-emitted static-dispatch JS against the
// idiomatic Node EventEmitter dynamic-dispatch version and the plain-nested-loop
// floor, on the identical depth-3 nested chain.
//
// Method:
//   - Each candidate is run in a fresh `node <file> <n>` process (child_process).
//   - For each n, 5 runs, take the MEDIAN wall time.
//   - A `node -e ""` empty-startup baseline (5 runs, median) is measured and
//     SUBTRACTED from every measurement to isolate compute from interpreter
//     startup. This is the honesty knob: without it the numbers are dominated
//     by V8 boot, not by the dispatch chain.
//   - Before timing, all three candidates are run once per n and their stdout
//     compared — a perf comparison of different answers is meaningless.

import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));

const NODE = process.execPath;
const RUNS = 5;
const NS = [100, 200, 300]; // 10^3 inner iterations: 1e6, 8e6, 2.7e7

const candidates = {
  "koru-static": join(__dirname, "chain_koru_static.js"),
  dynamic: join(__dirname, "chain_dynamic.mjs"),
  flat: join(__dirname, "chain_flat.mjs"),
};

function median(xs) {
  const s = [...xs].sort((a, b) => a - b);
  const m = Math.floor(s.length / 2);
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
}

function timeRun(file, n) {
  const start = process.hrtime.bigint();
  const res = spawnSync(NODE, [file, String(n)], { encoding: "utf8" });
  const end = process.hrtime.bigint();
  if (res.status !== 0) {
    throw new Error(
      `run failed: ${NODE} ${file} ${n}\nstatus=${res.status}\nstderr=${res.stderr}`,
    );
  }
  const ms = Number(end - start) / 1e6;
  return { ms, stdout: res.stdout.trim() };
}

function timeBaseline() {
  const samples = [];
  for (let i = 0; i < RUNS; i++) {
    const start = process.hrtime.bigint();
    const res = spawnSync(NODE, ["-e", ""], { encoding: "utf8" });
    const end = process.hrtime.bigint();
    if (res.status !== 0) throw new Error(`baseline failed: ${res.stderr}`);
    samples.push(Number(end - start) / 1e6);
  }
  return median(samples);
}

// --- correctness gate: all three must agree per n ---
for (const n of NS) {
  const outputs = {};
  for (const [name, file] of Object.entries(candidates)) {
    outputs[name] = timeRun(file, n).stdout;
  }
  const distinct = new Set(Object.values(outputs));
  if (distinct.size !== 1) {
    console.error(`MISMATCH at n=${n}:`, outputs);
    process.exit(1);
  }
  console.error(`n=${n}: all agree -> ${[...distinct][0]}`);
}

const baseline = timeBaseline();
console.error(`\nnode -e "" startup baseline (median of ${RUNS}): ${baseline.toFixed(2)} ms`);
console.error("(subtracted from every measurement below)\n");

// --- timing sweep ---
const rows = [];
for (const n of NS) {
  const med = {};
  for (const [name, file] of Object.entries(candidates)) {
    const samples = [];
    for (let i = 0; i < RUNS; i++) samples.push(timeRun(file, n).ms);
    // baseline-subtract, clamp at 0 to avoid negative noise on tiny n.
    med[name] = Math.max(0, median(samples) - baseline);
  }
  rows.push({ n, ...med });
}

// --- table ---
const pad = (s, w) => String(s).padStart(w);
console.log(
  [
    pad("n", 6),
    pad("koru-static ms", 16),
    pad("dynamic ms", 12),
    pad("flat ms", 10),
    pad("dyn/koru", 9),
    pad("koru/flat", 10),
  ].join("  "),
);
console.log("-".repeat(70));
for (const r of rows) {
  const k = r["koru-static"];
  const d = r.dynamic;
  const f = r.flat;
  console.log(
    [
      pad(r.n, 6),
      pad(k.toFixed(2), 16),
      pad(d.toFixed(2), 12),
      pad(f.toFixed(2), 10),
      pad((d / k).toFixed(2) + "x", 9),
      pad((k / f).toFixed(2) + "x", 10),
    ].join("  "),
  );
}
