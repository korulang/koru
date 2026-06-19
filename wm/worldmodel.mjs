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

const ROOT = process.argv[2] || dirname(dirname(fileURLToPath(import.meta.url))); // wm/ -> repo root
const SUBJECT = basename(ROOT);

// --- WHAT IT WATCHES: instruments discovered by convention (the shapes wm knows) ---
const instruments = [];
if (existsSync(join(ROOT, 'wm', 'run.sh')))
  instruments.push({ id: 'wm-adapter', shape: 'adapter', path: 'wm/run.sh',
    watches: 'koru regression suite — fires when a green test flips red' });
const modelsDir = join(ROOT, 'models');
if (existsSync(modelsDir))
  for (const d of readdirSync(modelsDir))
    if (existsSync(join(modelsDir, d, 'run.sh')))
      instruments.push({ id: d, shape: 'native', path: `models/${d}/run.sh` });

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

// --- write the generated manifest ---
writeFileSync(join(ROOT, 'wm', 'worldmodel.json'),
  JSON.stringify({ subject: SUBJECT, generated_at: new Date().toISOString(), scoreboard, instruments, floats }, null, 2) + '\n');

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
