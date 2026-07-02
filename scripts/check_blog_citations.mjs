#!/usr/bin/env node

/**
 * check_blog_citations.mjs — weld a narrative post to the test suite.
 *
 * A blog post that cites regression tests by ID will rot the moment one of
 * those tests changes color. This makes that rot LOUD: it reads a post, pulls
 * every NNN_NNN id out of the prose, and checks each one against the latest
 * regression snapshot.
 *
 * Contract carried IN the post (an HTML comment, so it never renders):
 *
 *     green:    <space-separated ids that MUST be `success`>
 *     frontier: <space-separated ids that MUST NOT be `success` — pinned intent>
 *
 * Rules enforced (any violation → exit 1):
 *   1. Every NNN_NNN id appearing anywhere in the post is classified (green or
 *      frontier). An unclassified citation is drift — you cited a test without
 *      saying what you claim about it.
 *   2. Every `green` id resolves to a snapshot test with status === "success".
 *   3. Every `frontier` id resolves to a snapshot test with status !== "success".
 *      (If a frontier test goes green, that's GOOD news — but the post is now
 *      stale and must promote it. So we still fail, loudly, with that reason.)
 *
 * The check reads test-results/latest.json (the snapshot the ceremony refreshes),
 * not a live run — it prints the snapshot's timestamp + commit so staleness is
 * visible. Pass --snapshot <path> to point at a different one.
 *
 * Usage:
 *   node scripts/check_blog_citations.mjs [post.md] [--snapshot test-results/latest.json]
 *   (default post: docs/blog_effect_branch_resume_draft.md)
 */

import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, '..');

// ---- args --------------------------------------------------------------
const argv = process.argv.slice(2);
let postPath = path.join(ROOT, 'docs', 'blog_effect_branch_resume_draft.md');
let snapshotPath = path.join(ROOT, 'test-results', 'latest.json');
for (let i = 0; i < argv.length; i++) {
  if (argv[i] === '--snapshot') snapshotPath = path.resolve(argv[++i]);
  else if (!argv[i].startsWith('--')) postPath = path.resolve(argv[i]);
}

const RED = (s) => `\x1b[0;31m${s}\x1b[0m`;
const GREEN = (s) => `\x1b[0;32m${s}\x1b[0m`;
const DIM = (s) => `\x1b[2m${s}\x1b[0m`;

function die(msg) {
  console.error(RED(`❌ blog-citations: ${msg}`));
  process.exit(1);
}

if (!fs.existsSync(postPath)) die(`post not found: ${postPath}`);
if (!fs.existsSync(snapshotPath)) die(`snapshot not found: ${snapshotPath}`);

const post = fs.readFileSync(postPath, 'utf8');
const snapshot = JSON.parse(fs.readFileSync(snapshotPath, 'utf8'));

// ---- build id -> status from the snapshot ------------------------------
// A test directory looks like `400_082_effect_branch_resume_value`; its id is
// the first two underscore-separated segments: `400_082`.
const idStatus = new Map();
for (const cat of snapshot.categories ?? []) {
  for (const t of cat.tests ?? []) {
    const id = (t.directory ?? '').split('_').slice(0, 2).join('_');
    if (/^\d{3}_\d{3}$/.test(id)) idStatus.set(id, t.status);
  }
}

// ---- parse the post ----------------------------------------------------
const proseIds = new Set([...post.matchAll(/\b(\d{3}_\d{3})\b/g)].map((m) => m[1]));

function parseList(label) {
  const re = new RegExp(`^${label}:\\s*(.*)$`, 'm');
  const m = post.match(re);
  if (!m) return null;
  return new Set(m[1].trim().split(/\s+/).filter((s) => /^\d{3}_\d{3}$/.test(s)));
}
const green = parseList('green');
const frontier = parseList('frontier');

if (!green || !frontier)
  die(`post is missing a CITATIONS manifest (need both 'green:' and 'frontier:' lines)`);

// ---- rule 1: every prose id is classified ------------------------------
const classified = new Set([...green, ...frontier]);
const unclassified = [...proseIds].filter((id) => !classified.has(id)).sort();

// ---- rules 2 & 3: snapshot status matches the claim --------------------
const failures = [];
for (const id of [...green].sort()) {
  const st = idStatus.get(id);
  if (st === undefined) failures.push(`green ${id}: not in snapshot`);
  else if (st !== 'success') failures.push(`green ${id}: claimed green but snapshot status is '${st}'`);
}
for (const id of [...frontier].sort()) {
  const st = idStatus.get(id);
  if (st === undefined) failures.push(`frontier ${id}: not in snapshot`);
  else if (st === 'success')
    failures.push(`frontier ${id}: claimed frontier but snapshot says 'success' — PROMOTE it into the body`);
}

// ---- report ------------------------------------------------------------
console.log(`blog-citations — ${path.relative(ROOT, postPath)}`);
console.log(
  DIM(`  snapshot ${path.relative(ROOT, snapshotPath)} @ ${snapshot.gitCommit ?? '?'} (${snapshot.timestamp ?? '?'})`),
);
console.log(DIM(`  cited: ${proseIds.size}  green: ${green.size}  frontier: ${frontier.size}`));

let ok = true;
if (unclassified.length) {
  ok = false;
  console.error(RED(`  unclassified citations (cite ⇒ classify): ${unclassified.join(' ')}`));
}
for (const f of failures) {
  ok = false;
  console.error(RED(`  ${f}`));
}

if (!ok) {
  console.error(RED(`❌ blog-citations FAILED — the post has drifted from the suite.`));
  process.exit(1);
}
console.log(GREEN(`✅ blog-citations OK — every cited test matches its claimed status.`));
