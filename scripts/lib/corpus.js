/**
 * Shared corpus-collection helpers.
 *
 * The reference corpus (generate-corpus.js), the teaching tutorial
 * (generate-tutorial.js) and the per-topic skill bundles
 * (generate-skills.js) all walk `tests/regression/` the same way: keep the
 * passing POSITIVE tests, drop the negative MUST_FAIL ones, read the source
 * verbatim. That walk lived in three near-identical copies; this is the one
 * copy they share.
 */

import fs from 'fs';
import path from 'path';

/**
 * Walk `dir`, collecting every passing POSITIVE test (has a SUCCESS marker,
 * no MUST_FAIL marker). Negative tests "pass" by being rejected — they are
 * examples of what the compiler REJECTS, never what-to-do — so they are
 * excluded from every generated artifact and tracked separately so config
 * references to them can warn specifically instead of silently vanishing.
 *
 * Returns { tests, negativeTests }:
 *   tests        — array of { name, breadcrumbs, dir, input, expected }
 *   negativeTests — Set of basenames of excluded MUST_FAIL tests
 *
 * `breadcrumbs` is the category path above the test (its own dir name dropped),
 * so a test at 300_ADVANCED_FEATURES/330_PHANTOM_TYPES/330_005_foo carries
 * breadcrumbs ["300_ADVANCED_FEATURES", "330_PHANTOM_TYPES"].
 */
export function collectPassing(dir) {
  const negativeTests = new Set();
  const tests = walk(dir, [], negativeTests);
  return { tests, negativeTests };
}

function walk(dir, breadcrumbs, negativeTests) {
  const entries = fs.readdirSync(dir, { withFileTypes: true });
  const hasSuccess = entries.some((e) => e.isFile() && e.name === 'SUCCESS');

  if (hasSuccess) {
    // A MUST_FAIL test is negative: it passes by being rejected. Exclude it
    // from the positive example set — every artifact shows what TO do.
    if (entries.some((e) => e.isFile() && e.name === 'MUST_FAIL')) {
      negativeTests.add(path.basename(dir));
      return [];
    }
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
        name: path.basename(dir),
        breadcrumbs: breadcrumbs.slice(0, -1),
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
      out.push(...walk(path.join(dir, e.name), [...breadcrumbs, e.name], negativeTests));
    }
  }
  return out;
}

/**
 * Resolve a list of `clusters` (raw breadcrumb paths like
 * "300_ADVANCED_FEATURES" or "300_ADVANCED_FEATURES / 330_PHANTOM_TYPES") to
 * the passing tests living under those subtrees, at any depth. Returns a
 * Map name->test (insertion-ordered) plus the cluster strings that matched
 * nothing, so callers can warn on stale config.
 */
export function resolveClusters(allTests, clusters) {
  const matched = new Map();
  const unknown = [];
  for (const cluster of clusters) {
    const segments = cluster.split(' / ').map((s) => s.trim()).filter(Boolean);
    let count = 0;
    for (const t of allTests) {
      if (t.breadcrumbs.length < segments.length) continue;
      let isMatch = true;
      for (let i = 0; i < segments.length; i++) {
        if (t.breadcrumbs[i] !== segments[i]) { isMatch = false; break; }
      }
      if (isMatch) {
        matched.set(t.name, t);
        count++;
      }
    }
    if (count === 0) unknown.push(cluster);
  }
  return { matched, unknown };
}

/**
 * Demote every markdown heading by one level so pulled prose nests cleanly
 * under a generated H1/H2 structure. H6 is the floor. Lines inside fenced
 * code blocks are skipped so bash comments (`# foo`) aren't clobbered.
 */
export function demoteHeadings(md) {
  const lines = md.split('\n');
  let inFence = false;
  for (let i = 0; i < lines.length; i++) {
    if (/^```/.test(lines[i])) {
      inFence = !inFence;
      continue;
    }
    if (inFence) continue;
    lines[i] = lines[i].replace(/^(#{1,5}) /, '$1# ');
  }
  return lines.join('\n');
}

/** Strip numeric prefixes and underscores from a slug for display. */
export function humanize(slug) {
  return slug.replace(/^(\d+_)+/, '').replace(/_/g, ' ');
}

/**
 * Emit one test as a `### name` section: the source verbatim in a ```koru
 * fence, then the expected output (if any) under an **Output:** label.
 */
export function emitTest(t, lines) {
  lines.push(`### ${t.name}`);
  lines.push('');
  lines.push('```koru');
  for (const line of t.input.replace(/\n+$/, '').split('\n')) lines.push(line);
  lines.push('```');
  lines.push('');
  if (t.expected !== null && t.expected.trim() !== '') {
    lines.push('**Output:**');
    lines.push('');
    lines.push('```');
    for (const line of t.expected.replace(/\n+$/, '').split('\n')) lines.push(line);
    lines.push('```');
    lines.push('');
  }
}
