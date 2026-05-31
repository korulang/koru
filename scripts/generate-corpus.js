#!/usr/bin/env node

/**
 * Generate koru-by-example.md from a curated test list.
 *
 * Model:
 *   - koru-by-example.json holds an `included` array of test directory
 *     names. The doc shows ONLY these tests, grouped by category.
 *   - Category prose is pulled from existing SPEC.md or README.md in the
 *     category directory. Drift is tolerated; cleaning is a separate pass.
 *   - Per-test prose is intentionally NOT pulled. Tests speak for
 *     themselves. If a test cannot speak for itself, that's a
 *     test-clarity problem, not a fix-with-a-comment problem.
 *
 * Output:
 *   1. Top-level prose (tests/regression/README.md, headings demoted)
 *   2. Table of contents (one row per category that has picks)
 *   3. Per-category sections: top-level prose → sub-category prose →
 *      picked tests verbatim
 */

import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, '..');
const TESTS_DIR = path.join(ROOT, 'tests', 'regression');
const OUTPUT = path.join(ROOT, 'koru-by-example.md');
const CONFIG = path.join(ROOT, 'koru-by-example.json');

// ----------------------------------------------------------------------
// Filesystem helpers
// ----------------------------------------------------------------------

function collectPassing(dir, breadcrumbs = []) {
  const entries = fs.readdirSync(dir, { withFileTypes: true });
  const hasSuccess = entries.some((e) => e.isFile() && e.name === 'SUCCESS');

  if (hasSuccess) {
    // Tests split into the `.k` + host form keep the host bindings (e.g. Zig
    // consts) in input.kz and the portable Koru in input.k. Show them as a
    // single block — host consts first, then the Koru — which reproduces the
    // pre-split example. Tests not yet split keep all their Koru in input.kz,
    // so the kz-only path is unchanged.
    const inputKzPath = path.join(dir, 'input.kz');
    const inputKPath = path.join(dir, 'input.k');
    const parts = [];
    if (fs.existsSync(inputKzPath))
      parts.push(fs.readFileSync(inputKzPath, 'utf-8').replace(/\n+$/, ''));
    if (fs.existsSync(inputKPath))
      parts.push(fs.readFileSync(inputKPath, 'utf-8').replace(/\n+$/, ''));
    if (parts.length === 0) return [];
    const expectedPath = path.join(dir, 'expected.txt');
    return [
      {
        breadcrumbs: breadcrumbs.slice(0, -1),
        name: path.basename(dir),
        dir,
        input: parts.join('\n\n') + '\n',
        expected: fs.existsSync(expectedPath)
          ? fs.readFileSync(expectedPath, 'utf-8')
          : null,
      },
    ];
  }

  const out = [];
  for (const e of entries) {
    if (e.isDirectory()) {
      out.push(
        ...collectPassing(path.join(dir, e.name), [...breadcrumbs, e.name])
      );
    }
  }
  return out;
}

// SPEC.md is preferred (substantial framing). README.md is fallback.
// Returns { content, relPath, source } or null.
function categoryProse(segments) {
  if (segments.length === 0) return null;
  const dir = path.join(TESTS_DIR, ...segments);
  if (!fs.existsSync(dir)) return null;
  for (const name of ['SPEC.md', 'README.md']) {
    const p = path.join(dir, name);
    if (fs.existsSync(p)) {
      return {
        content: fs.readFileSync(p, 'utf-8'),
        relPath: path.relative(ROOT, p),
        source: name,
      };
    }
  }
  return null;
}

// Demote every markdown heading by one level so pulled prose nests
// cleanly under our H1/H2 structure. H6 is the floor — don't go past it.
// Skip lines inside fenced code blocks so bash comments (`# foo`) and
// other `#`-prefixed code don't get clobbered.
function demoteHeadings(md) {
  const lines = md.split('\n');
  let inFence = false;
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (/^```/.test(line)) {
      inFence = !inFence;
      continue;
    }
    if (inFence) continue;
    lines[i] = line.replace(/^(#{1,5}) /, '$1# ');
  }
  return lines.join('\n');
}

function humanize(slug) {
  return slug.replace(/^(\d+_)+/, '').replace(/_/g, ' ');
}

// ----------------------------------------------------------------------
// Emission
// ----------------------------------------------------------------------

function emitTest(t, lines) {
  lines.push(`### ${t.name}`);
  lines.push('');
  lines.push('```koru');
  for (const line of t.input.replace(/\n+$/, '').split('\n')) {
    lines.push(line);
  }
  lines.push('```');
  lines.push('');
  if (t.expected !== null && t.expected.trim() !== '') {
    lines.push('**Output:**');
    lines.push('');
    lines.push('```');
    for (const line of t.expected.replace(/\n+$/, '').split('\n')) {
      lines.push(line);
    }
    lines.push('```');
    lines.push('');
  }
}

function emitProse(prose, lines) {
  lines.push(`*Prose source: \`${prose.relPath}\` — may be drifted.*`);
  lines.push('');
  lines.push(demoteHeadings(prose.content.replace(/\n+$/, '')));
  lines.push('');
  lines.push('---');
  lines.push('');
}

// ----------------------------------------------------------------------
// Main
// ----------------------------------------------------------------------

const config = JSON.parse(fs.readFileSync(CONFIG, 'utf-8'));
const categories = config.categories ?? [];
const includedTests = config.includedTests ?? [];
const excludedTests = new Set(config.excludedTests ?? []);

const allTests = collectPassing(TESTS_DIR);
const byName = new Map(allTests.map((t) => [t.name, t]));

// Resolve `categories` to passing tests. A category entry is a raw
// breadcrumb path like "300_ADVANCED_FEATURES" or "300_ADVANCED_FEATURES /
// 330_PHANTOM_TYPES". Tests under that subtree (at any depth) match.
const fromCategories = new Map(); // name -> test
const unknownCategories = [];
for (const cat of categories) {
  const catSegments = cat.split(' / ').map((s) => s.trim()).filter(Boolean);
  let matched = 0;
  for (const t of allTests) {
    const tPath = t.breadcrumbs;
    if (tPath.length < catSegments.length) continue;
    let isMatch = true;
    for (let i = 0; i < catSegments.length; i++) {
      if (tPath[i] !== catSegments[i]) { isMatch = false; break; }
    }
    if (isMatch) {
      fromCategories.set(t.name, t);
      matched++;
    }
  }
  if (matched === 0) unknownCategories.push(cat);
}
if (unknownCategories.length > 0) {
  console.warn('[warn] categories with no matching passing tests:');
  for (const c of unknownCategories) console.warn(`         ${c}`);
}

// Layer in individual `includedTests` on top of the category picks.
const missing = [];
for (const name of includedTests) {
  if (byName.has(name)) {
    fromCategories.set(name, byName.get(name));
  } else {
    missing.push(name);
  }
}
if (missing.length > 0) {
  console.warn('[warn] includedTests not found (or not passing):');
  for (const name of missing) console.warn(`         ${name}`);
}

// Apply exclusions. Warn on stale entries.
for (const name of excludedTests) {
  if (!byName.has(name)) {
    console.warn(`[warn] excludedTests entry not found: ${name}`);
  }
  fromCategories.delete(name);
}

const picked = [...fromCategories.values()];

// Group by full raw breadcrumb path. Sort group keys alphabetically —
// directory naming uses numeric prefixes (000_, 100_, etc.), so
// alphabetical = intended category order. Tests within a group keep
// their JSON authoring order, then fall back to name sort for stability.
const groups = new Map();
for (const t of picked) {
  const key = t.breadcrumbs.join(' / ');
  if (!groups.has(key)) groups.set(key, []);
  groups.get(key).push(t);
}
const sortedGroupKeys = [...groups.keys()].sort();

// ----------------------------------------------------------------------
// Build the document
// ----------------------------------------------------------------------

const lines = [];

// 1. Doc header + top-level prose
lines.push('# Koru by Example');
lines.push('');
lines.push(
  `> ${picked.length} hand-picked tests from \`tests/regression/\`. ` +
    `Generated ${new Date().toISOString()} by \`scripts/generate-corpus.js\`.`
);
lines.push('');
lines.push(
  'Every example below is verbatim source from a passing regression test. ' +
    'Section prose is pulled from existing `SPEC.md` / `README.md` files in ' +
    'the relevant category directories — drift is tolerated in this pass ' +
    "and cleaned in a separate sweep. Per-test prose is intentionally NOT " +
    'pulled; tests speak for themselves.'
);
lines.push('');
lines.push('---');
lines.push('');

// Pull tests/regression/{SPEC,README}.md as the doc preamble.
for (const name of ['SPEC.md', 'README.md']) {
  const p = path.join(TESTS_DIR, name);
  if (fs.existsSync(p)) {
    emitProse(
      {
        content: fs.readFileSync(p, 'utf-8'),
        relPath: path.relative(ROOT, p),
        source: name,
      },
      lines
    );
    break;
  }
}

// 2. Table of contents
lines.push('## Contents');
lines.push('');
for (const groupKey of sortedGroupKeys) {
  const display =
    groupKey === ''
      ? '(uncategorized)'
      : groupKey.split(' / ').map(humanize).join(' / ');
  const count = groups.get(groupKey).length;
  lines.push(`- **${display}** — ${count} ${count === 1 ? 'test' : 'tests'}`);
}
lines.push('');
lines.push('---');
lines.push('');

// 3. Per-category sections
let lastTopRaw = null;
for (const groupKey of sortedGroupKeys) {
  const groupTests = groups.get(groupKey);
  const segments = groupKey === '' ? [] : groupKey.split(' / ');

  if (segments.length === 0) {
    // Uncategorized bucket — no header, just emit tests
    for (const t of groupTests) emitTest(t, lines);
    continue;
  }

  const topRaw = segments[0];
  if (topRaw !== lastTopRaw) {
    lines.push(`# ${humanize(topRaw)}`);
    lines.push('');
    const tp = categoryProse([topRaw]);
    if (tp) emitProse(tp, lines);
    lastTopRaw = topRaw;
  }

  if (segments.length > 1) {
    lines.push(`## ${segments.slice(1).map(humanize).join(' / ')}`);
    lines.push('');
    const sp = categoryProse(segments);
    if (sp) emitProse(sp, lines);
  }

  for (const t of groupTests) emitTest(t, lines);
}

// ----------------------------------------------------------------------
// Write
// ----------------------------------------------------------------------

const body = lines.join('\n') + '\n';
fs.writeFileSync(OUTPUT, body);

const stats = fs.statSync(OUTPUT);
const sizeKB = (stats.size / 1024).toFixed(1);
const totalLines = body.split('\n').length;

console.log(`Wrote ${path.relative(ROOT, OUTPUT)}`);
console.log(`  ${picked.length} tests across ${groups.size} categories`);
console.log(`  ${sizeKB} KB, ${totalLines} lines`);
if (missing.length > 0) {
  console.log(`  ${missing.length} included entries missing (see warnings)`);
}
