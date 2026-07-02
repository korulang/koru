#!/usr/bin/env node
// Producer: a repo's real git history → replay cassette (data/series.csv). No
// synthesis, no Convex — just `git log`. value = inter-commit gap in minutes.
//   node gitcsv.mjs <repo> <out.csv>
import { execFileSync } from "node:child_process";
import { writeFileSync, mkdirSync } from "node:fs";
import path from "node:path";

const repo = process.argv[2] || ".";
const out = process.argv[3] || "models/commit_cadence/data/series.csv";
const raw = execFileSync(
  "git",
  ["-C", repo, "log", "--reverse", "--no-merges", "--pretty=format:%H%x1f%aI%x1f%s", "--shortstat"],
  { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 },
);

const commits = [];
let cur = null;
for (const line of raw.split("\n")) {
  if (line.includes("\x1f")) {
    if (cur) commits.push(cur);
    const [sha, iso, subject] = line.split("\x1f");
    cur = { sha, iso, files: 0, ins: 0, del: 0, subject: (subject || "").replace(/,/g, " ") };
  } else if (line.includes("changed") && cur) {
    const f = line.match(/(\d+) files? changed/), i = line.match(/(\d+) insertions?/), d = line.match(/(\d+) deletions?/);
    if (f) cur.files = +f[1];
    if (i) cur.ins = +i[1];
    if (d) cur.del = +d[1];
  }
}
if (cur) commits.push(cur);
if (!commits.length) throw new Error("gitcsv: no commits — thin history is a real state, not paperable.");

mkdirSync(path.dirname(out), { recursive: true });
const rows = ["idx,iso,gap_min,files,ins,del,sha,subject"];
let prev = null;
commits.forEach((c, idx) => {
  const ts = Date.parse(c.iso);
  const gap = prev == null ? 0 : (ts - prev) / 60000;
  prev = ts;
  const isoUtc = new Date(ts).toISOString().replace(/\.\d+Z$/, "");
  rows.push(`${idx},${isoUtc},${gap.toFixed(1)},${c.files},${c.ins},${c.del},${c.sha.slice(0, 12)},${c.subject}`);
});
writeFileSync(out, rows.join("\n") + "\n");
console.error(`gitcsv: wrote ${commits.length} commits → ${out}`);
