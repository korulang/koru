#!/usr/bin/env node
// worldmodel.mjs — generate + render a repo's world-model state: WHAT IT WATCHES + WHAT IT'S MISSING.
//
// FIRST CUT, deliberately living in the koru worktree so we can go bananas. It is target-agnostic
// (give it a repo path, or it defaults to the repo it lives in) and reads ONLY by convention —
// the same shapes `wm` uses (wm/run.sh, models/*/run.sh) plus float commission queues. It writes a
// generated wm/worldmodel.json (do-not-hand-edit) and prints the human view. Graduates to the
// general wm-cli later; for now it is the fastest path to EYES.

import { readFileSync, writeFileSync, existsSync, readdirSync } from 'node:fs';
import { join, dirname, basename } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const ROOT = process.argv[2] || dirname(dirname(fileURLToPath(import.meta.url))); // wm/ -> repo root
const SUBJECT = basename(ROOT);

// --- WHAT IT WATCHES: native WMFX models RUN THROUGH THE ENGINE; signals scraped from it ---
// The honest source is `wm run <root> --only <model> --json`: it transpiles model.wmfx,
// drives the engine against the oracle, and reports the `signal` lines the model fired.
// "green" here means a real model ran — it can never mean "a script printed a number".
const WATCHES = {
  breath:
    "koru's pass-rate across its whole snapshot history — fires when the breath goes wrong: " +
    'a drawdown held ≥8pp below the running peak for longer than anything the in-sample ' +
    'bring-up ever showed (a long inhale that never exhaled).',
  'wm-adapter':
    'koru regression suite — the wall that writes each snapshot; fires (red) when a green test flips red',
};

// Parse a native model's per-tick engine output (data/signal.csv) into a generic
// series the page can chart for ANY instrument that emits one. No model knowledge here.
function parseSeries(csv) {
  const lines = csv.trim().split('\n');
  lines.shift(); // header: idx,iso,rate,dip,alarm,slice
  const points = [];
  for (const ln of lines) {
    if (!ln.trim()) continue;
    const [idx, iso, rate, dip, alarm, slice] = ln.split(',');
    points.push({
      x: Number(idx), iso, y: Number(rate), dip: Number(dip),
      fired: Number(alarm) >= 0.5, phase: slice === 'IS' ? 'in_sample' : 'oos',
    });
  }
  return { x_label: 'snapshot #', y_label: 'pass rate %', points };
}

const instruments = [];
const modelsDir = join(ROOT, 'models');

// The adapter (wm/run.sh) is the regression wall — heavy and snapshot-WRITING. It is
// LISTED here (its world-state readout IS the scoreboard below), but NOT fired during
// page generation; the status ceremony is what runs it.
if (existsSync(join(ROOT, 'wm', 'run.sh')))
  instruments.push({ id: 'wm-adapter', shape: 'adapter', path: 'wm/run.sh',
    watches: WATCHES['wm-adapter'], run_by: 'status ceremony (not page generation)' });

// Native WMFX models — discovered by convention, then ACTUALLY RUN through the engine
// so the manifest carries real fired signals (and the per-tick curve), not a re-scan.
const nativeModels = existsSync(modelsDir)
  ? readdirSync(modelsDir).filter((d) => existsSync(join(modelsDir, d, 'model.wmfx')))
  : [];
for (const name of nativeModels) {
  const r = spawnSync('wm', ['run', ROOT, '--only', name, '--json'],
    { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
  if (!r.stdout) {
    console.error(r.stderr || String(r.error));
    throw new Error(`wm run --only ${name} produced no JSON — the engine did not run. ` +
      'Refusing to emit a manifest without it (a manifest with faked signals is worse than none).');
  }
  const doc = JSON.parse(r.stdout);
  const got = (doc.instruments || []).find((i) => i.name === name);
  if (!got) throw new Error(`wm did not return instrument '${name}' — discovery/engine mismatch.`);
  const inst = {
    id: name, shape: 'native', path: `models/${name}/model.wmfx`,
    watches: WATCHES[name], pass: got.pass, signals: got.signals || [],
  };
  const sigCsv = join(modelsDir, name, 'data', 'signal.csv');
  if (existsSync(sigCsv)) inst.series = parseSeries(readFileSync(sigCsv, 'utf8'));
  instruments.push(inst);
}

// --- WHAT IT'S MISSING: every float's commission queue ---
const floatsDir = join(ROOT, 'wm', 'floats');
const floats = [];
if (existsSync(floatsDir))
  for (const d of readdirSync(floatsDir)) {
    const f = join(floatsDir, d, 'commission_queue.json');
    if (!existsSync(f)) continue;
    let doc; try { doc = JSON.parse(readFileSync(f, 'utf8')); } catch { continue; }
    const gaps = doc.commission_queue || [];
    floats.push({ float: d, date: doc.date || '?', count: doc.candidate_count ?? gaps.length, gaps });
  }
floats.sort((a, b) => (a.date < b.date ? -1 : 1));

const isRejected = (g) => (g.status || '').toLowerCase().startsWith('reject');
const isBuilt = (g) => /built/i.test(g.status || '') ||
  (/registry coherence/i.test(g.title || '') && existsSync(join(ROOT, 'scripts', 'registry_check.zig')));
const isConverged = (g) => g.converged || (Array.isArray(g.corroborated_by) && g.corroborated_by.length > 1);

// --- substrate tally (the "is this really world-modeling?" answer) ---
let nTest = 0, nInstr = 0, nRej = 0, nTotal = 0;
for (const fl of floats) for (const g of fl.gaps) {
  nTotal++;
  if (isRejected(g)) { nRej++; continue; }
  if ((g.substrate || '').toLowerCase().includes('instr')) nInstr++; else nTest++;
}

// --- live scoreboard: the goal↔current breath, read from the latest snapshot ---
// The aggregate that belongs in the world model (the rollup, not the 866 atoms):
// passing vs expected, and the gap below the all-pass setpoint.
let scoreboard = null;
const snapPath = join(ROOT, 'test-results', 'latest.json');
if (existsSync(snapPath)) {
  try {
    const s = JSON.parse(readFileSync(snapPath, 'utf8')).summary;
    scoreboard = { passed: s.passed, expected: s.inScope, gap: s.inScope - s.passed, pass_rate: s.passRate };
  } catch { /* no readable snapshot — leave null, the page handles its absence */ }
}

// --- perf: world (measured) vs model (the promise), from the benchmark results ---
// Same source the perf-promise probe reads; here we keep the per-workload detail the
// scalar `signal` lines can't carry, so the page can VISUALIZE world-vs-model.
let perf = null;
const benchDir = join(ROOT, 'benchmarks', 'results');
if (existsSync(benchDir)) {
  const wl = {};
  for (const f of readdirSync(benchDir).filter((f) => f.endsWith('.csv'))) {
    for (const ln of readFileSync(join(benchDir, f), 'utf8').split('\n').slice(1)) {
      if (!ln.trim()) continue;
      const [workload, lang, n, wall] = ln.split(',');
      const ms = parseFloat(wall);
      const ni = parseInt(n, 10);
      if (!workload || !lang || isNaN(ms) || isNaN(ni)) continue;
      (wl[workload] ??= {});
      // Compute-bound comparison: keep the wall time at the LARGEST n. The loop
      // dominates there, not process startup. `min` across sizes hid the real
      // per-iteration cost behind the smallest-n startup floor — which (with
      // koru's output binary having been built ReleaseSmall until 220ec600) is
      // exactly what masked koru's true parity with Rust.
      const cur = wl[workload][lang];
      if (!cur || ni > cur.n) wl[workload][lang] = { n: ni, ms };
    }
  }
  const workloads = Object.entries(wl)
    .filter(([, l]) => l.koru !== undefined)
    .map(([workload, langs]) => {
      const koru = langs.koru.ms;
      const field = Object.entries(langs)
        .filter(([l]) => l !== 'koru')
        .map(([lang, v]) => ({ lang, ms: v.ms }))
        .sort((a, b) => a.ms - b.ms);
      const rival = field[0] ?? null;
      return {
        workload, koru, rival, fieldCount: field.length,
        max: Math.max(koru, rival ? rival.ms : koru),
        fastest: rival ? koru <= rival.ms : true,
        host_backed: langs.zig !== undefined,
      };
    });
  perf = {
    promise_host: 'within 10% of the host language (Zig)',
    workloads,
    host_backed: workloads.filter((w) => w.host_backed).length,
    koru_fastest: workloads.filter((w) => w.fastest).length,
  };
}

// --- write the generated manifest ---
writeFileSync(join(ROOT, 'wm', 'worldmodel.json'),
  JSON.stringify({ subject: SUBJECT, generated_at: new Date().toISOString(), scoreboard, perf, instruments, floats }, null, 2) + '\n');

// --- render the EYES ---
const c = { dim: '\x1b[2m', b: '\x1b[1m', g: '\x1b[32m', y: '\x1b[33m', r: '\x1b[31m', cy: '\x1b[36m', x: '\x1b[0m' };
const bar = `${c.b}${c.cy}${'═'.repeat(60)}${c.x}`;
const sv = (g) => `${String(g.severity || '?').padEnd(4)}·${g.buildability || '?'}`;
const out = [];
out.push('', bar, `${c.b}  WORLD-MODEL  ·  ${SUBJECT}${c.x}`, bar, '');

out.push(`${c.b}WHAT IT WATCHES${c.x}  —  ${instruments.length} instrument${instruments.length === 1 ? '' : 's'}`);
if (!instruments.length) out.push(`  ${c.dim}(none yet)${c.x}`);
for (const i of instruments) {
  out.push(`  ${c.g}●${c.x} ${c.b}${i.id}${c.x}  ${c.dim}[${i.shape} · ${i.path}]${c.x}`);
  if (i.watches) out.push(`      ${c.dim}${i.watches}${c.x}`);
  if (i.signals && i.signals.length)
    out.push(`      ${c.g}signals${c.x} ${c.dim}${i.signals
      .map((s) => `${s.name}=${s.value}${s.unit ? ` ${s.unit}` : ''}`).join('  ')}${c.x}`);
}
out.push('');

out.push(`${c.b}WHAT IT'S MISSING${c.x}  —  gaps surfaced by hunts, not yet built  ${c.dim}(⊙⊙ = blind agents converged)${c.x}`);
for (const fl of floats) {
  out.push('', `  ${c.cy}▸ ${fl.date} · ${fl.float}${c.x}  ${c.dim}(${fl.gaps.length} listed of ${fl.count})${c.x}`);
  for (const g of fl.gaps) {
    if (isRejected(g)) {
      out.push(`      ${c.r}✗${c.x} ${c.dim}${g.title}${c.x}`);
      out.push(`        ${c.r}REJECTED${c.x} ${c.dim}— ${(g.status || '').replace(/^rejected\s*—?\s*/i, '')}${c.x}`);
    } else {
      const anchor = g.anchor ? `  ${c.dim}${String(g.anchor).split(';')[0].slice(0, 40)}${c.x}` : '';
      out.push(`      ${c.y}[${sv(g)}]${c.x} ${g.title}${anchor}` +
        `${isConverged(g) ? ` ${c.cy}⊙⊙${c.x}` : ''}${isBuilt(g) ? `  ${c.g}✓ built${c.x}` : ''}`);
    }
  }
}
out.push('');

out.push(`${c.b}SUBSTRATE MIX${c.x}  ${c.dim}(the "is this really world-modeling?" answer)${c.x}`);
out.push(`  test/probe: ${c.b}${nTest}${c.x}    instrument: ${c.b}${nInstr}${c.x}    rejected: ${nRej}    total surfaced: ${nTotal}`);
out.push(`  ${c.dim}→ koru's gaps come back as deterministic checks, not temporal world-models — as predicted.${c.x}`);
out.push('', `${c.dim}manifest → wm/worldmodel.json  (generated — do not hand-edit)${c.x}`, '');
console.log(out.join('\n'));
