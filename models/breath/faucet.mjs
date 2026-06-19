#!/usr/bin/env node
// Breath faucet — koru's inhale/exhale series, drawn from REAL dated regression
// snapshots. NO synthesis: one row per committed snapshot in test-results/, in
// chronological order. This is a FAUCET (it produces the series a model drinks),
// not a model — it emits no `signal` and makes no claim. The breath model reads
// the series.csv this writes; the engine + oracle do the judging.
//
// One bar = one regression snapshot.  pass_rate = summary.passRate (passed/inScope,
// or passed/total in the pre-inScope era — the snapshot computes it per its era).
//
// Usage: node faucet.mjs [--csv <path>]   (default: data/series.csv beside this file)

import { readFileSync, writeFileSync, readdirSync, mkdirSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const snapDir = "/Users/larsde/src/koru/test-results";

const csvArgIdx = process.argv.indexOf("--csv");
const outPath = csvArgIdx >= 0 ? process.argv[csvArgIdx + 1] : join(here, "data", "series.csv");

// Timestamped snapshots only (skip latest.json / unit-tests.json — latest is a
// dup of the newest tick, and the filename timestamp is the clock). Lexical sort
// on the ISO-ish filename IS chronological order.
const files = readdirSync(snapDir)
  .filter((f) => /^\d{4}-\d{2}-\d{2}T.*\.json$/.test(f))
  .sort();

const rows = [];
for (const f of files) {
  let s;
  try {
    s = JSON.parse(readFileSync(join(snapDir, f), "utf8")).summary;
  } catch {
    continue; // a malformed/partial snapshot is skipped, not faked
  }
  if (!s) continue;
  const passed = s.passed ?? null;
  const total = s.total ?? null;
  const inScope = s.inScope ?? total; // pre-inScope era: scope == total
  if (passed == null || !inScope) continue;
  // Trust the snapshot's own computed passRate where present (it knows its era);
  // fall back to passed/inScope. parseFloat tolerates the string form ("92.4").
  const pass_rate =
    s.passRate != null ? parseFloat(s.passRate) : Math.round((passed / inScope) * 1000) / 10;
  if (!Number.isFinite(pass_rate)) continue;
  // ISO timestamp from the filename: 2026-01-26T21-37-24.json -> 2026-01-26T21:37:24
  const iso = f.replace(/\.json$/, "").replace(/T(\d{2})-(\d{2})-(\d{2}).*/, "T$1:$2:$3");
  rows.push({
    iso,
    passed,
    total: total ?? inScope,
    inScope,
    pass_rate,
    failed: s.failed ?? 0,
    todo: s.todo ?? 0,
  });
}

mkdirSync(join(here, "data"), { recursive: true });
const header = "idx,iso,pass_rate,passed,inScope,failed,todo";
const lines = rows.map(
  (r, i) => `${i},${r.iso},${r.pass_rate.toFixed(1)},${r.passed},${r.inScope},${r.failed},${r.todo}`,
);
writeFileSync(outPath, header + "\n" + lines.join("\n") + "\n");
console.error(`breath faucet: wrote ${rows.length} bars -> ${outPath}`);
