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
import {
  collectPassing,
  resolveClusters,
  demoteHeadings,
  humanize,
  emitTest,
} from './lib/corpus.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, '..');
const TESTS_DIR = path.join(ROOT, 'tests', 'regression');
const OUTPUT = path.join(ROOT, 'koru-by-example.md');
const CONFIG = path.join(ROOT, 'koru-by-example.json');

// ----------------------------------------------------------------------
// Filesystem helpers
// ----------------------------------------------------------------------

// PROSE KILLED. Category SPEC.md/README.md prose drifts and contaminates;
// the verbatim tests are the only source of truth. Always returns null.
function categoryProse() {
  return null;
}

// ----------------------------------------------------------------------
// Emission
// ----------------------------------------------------------------------

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

const { tests: allTests, negativeTests } = collectPassing(TESTS_DIR);
const byName = new Map(allTests.map((t) => [t.name, t]));

// Resolve `categories` to passing tests. A category entry is a raw
// breadcrumb path like "300_ADVANCED_FEATURES" or "300_ADVANCED_FEATURES /
// 330_PHANTOM_TYPES". Tests under that subtree (at any depth) match.
const { matched: fromCategories, unknown: unknownCategories } = resolveClusters(
  allTests,
  categories
);
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
  const negative = missing.filter((n) => negativeTests.has(n));
  const absent = missing.filter((n) => !negativeTests.has(n));
  if (negative.length > 0) {
    console.warn(
      '[warn] includedTests entries are NEGATIVE (MUST_FAIL) tests — excluded; ' +
        'examples must be positive (what-to-do):'
    );
    for (const name of negative) console.warn(`         ${name}`);
  }
  if (absent.length > 0) {
    console.warn('[warn] includedTests not found (or not passing):');
    for (const name of absent) console.warn(`         ${name}`);
  }
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
  'Every example below is verbatim source from a passing POSITIVE regression ' +
    'test (negative MUST_FAIL tests are excluded — these are all what-to-do). ' +
    'NO PROSE: category and per-test prose have been removed — the tests are the ' +
    'only source of truth (prose drifts and contaminates). These are the receipts.'
);
lines.push('');
lines.push('---');
lines.push('');

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
