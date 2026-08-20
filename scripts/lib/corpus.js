/**
 * Shared corpus-collection helpers.
 *
 * The reference corpus (generate-corpus.js), the teaching tutorial
 * (generate-tutorial.js) and the per-topic skill bundles
 * (generate-skills.js) all walk `tests/regression/` the same way: keep the
 * passing POSITIVE tests, drop the negative MUST_ERROR ones, read the source
 * verbatim. That walk lived in three near-identical copies; this is the one
 * copy they share.
 */

import fs from 'fs';
import path from 'path';

/**
 * Walk `dir`, collecting every passing POSITIVE test (has a SUCCESS marker,
 * no MUST_ERROR marker). Negative tests "pass" by being rejected — they are
 * examples of what the compiler REJECTS, never what-to-do — so they are
 * excluded from every generated artifact and tracked separately so config
 * references to them can warn specifically instead of silently vanishing.
 *
 * Returns { tests, negativeTests }:
 *   tests        — array of { name, breadcrumbs, dir, input, expected }
 *   negativeTests — Set of basenames of excluded MUST_ERROR tests
 *
 * `breadcrumbs` is the category path above the test (its own dir name dropped),
 * so a test at 300_ADVANCED_FEATURES/330_PHANTOM_TYPES/330_005_foo carries
 * breadcrumbs ["300_ADVANCED_FEATURES", "330_PHANTOM_TYPES"].
 */
/**
 * Refuse to build a corpus from a HALF-WRITTEN marker set.
 *
 * The SUCCESS markers `collectPassing` reads are transient run state: a suite
 * run clears them and rewrites them per-test as it goes. Generate against a
 * partial set and you get a corpus with a handful of tests in it — and the
 * generators write that over the committed docs and exit 0. On 2026-07-18 that
 * collapsed `koru-by-example.md` from 22 tests to 1 and deleted ~5000 lines
 * across `docs/by-example/` and `skills/`, silently, looking like a real diff.
 *
 * The stable reference is the last recorded run's own verdict —
 * `test-results/latest.json` `summary.passed`. A live marker count far below it
 * means a suite is mid-flight, not that the corpus shrank. Throw; the caller
 * exits. A generator that silently destroys committed work is worse than one
 * that stops.
 *
 * This is a wall, not a fallback: there is no degraded corpus, no partial
 * write, no "best effort". Either the markers are settled or nothing is
 * written.
 *
 * Absence of the reference is genuine optionality at a boundary — a fresh clone
 * has never run the suite — so it warns and proceeds rather than inventing a
 * verdict it cannot have.
 */
export function assertMarkerSetSettled(root, testsDir) {
  // Counted here rather than taken from the caller: `collectPassing` drops the
  // MUST_ERROR tests, but `summary.passed` counts them, and the comparison is
  // only honest between like and like — every SUCCESS marker on disk against
  // every test the last run recorded as passing.
  const liveCount = countSuccessMarkers(testsDir);
  const ref = path.join(root, 'test-results', 'latest.json');
  let expected;
  try {
    expected = JSON.parse(fs.readFileSync(ref, 'utf8'))?.summary?.passed;
  } catch {
    console.warn(
      '[warn] no test-results/latest.json — cannot tell a settled marker set ' +
        'from a mid-run one. Generating anyway; verify the output before committing.',
    );
    return;
  }
  if (typeof expected !== 'number' || expected <= 0) return;
  if (liveCount * 2 >= expected) return;

  throw new Error(
    `refusing to generate from a partial marker set: ${liveCount} live SUCCESS ` +
      `markers against ${expected} passing in test-results/latest.json.\n` +
      '  SUCCESS markers are transient — a suite run clears and rewrites them ' +
      'per-test.\n' +
      '  Generating now would overwrite the committed corpus with a truncated one.\n' +
      '  Let the suite finish (./run_regression.sh), then regenerate.',
  );
}

function countSuccessMarkers(dir) {
  let n = 0;
  let entries;
  try {
    entries = fs.readdirSync(dir, { withFileTypes: true });
  } catch {
    return 0;
  }
  if (entries.some((e) => e.isFile() && e.name === 'SUCCESS')) n += 1;
  for (const e of entries) {
    if (e.isDirectory()) n += countSuccessMarkers(path.join(dir, e.name));
  }
  return n;
}

export function collectPassing(dir) {
  const negativeTests = new Set();
  const tests = walk(dir, [], negativeTests);
  return { tests, negativeTests };
}

function walk(dir, breadcrumbs, negativeTests) {
  const entries = fs.readdirSync(dir, { withFileTypes: true });
  const hasSuccess = entries.some((e) => e.isFile() && e.name === 'SUCCESS');

  if (hasSuccess) {
    // A MUST_ERROR test is negative: it passes by being rejected. Exclude it
    // from the positive example set — every artifact shows what TO do.
    if (entries.some((e) => e.isFile() && e.name === 'MUST_ERROR')) {
      negativeTests.add(path.basename(dir));
      return [];
    }
    // Tests split into the `.k` + host form keep the host bindings (e.g. Zig
    // consts) in input.kz and the portable Koru in input.k. A `.kz` const
    // (`const count: i32 = 42;`) is ZIG text — concat it onto a pure `.k`
    // display and the shown file fails shape-check as pure Koru (KORU114),
    // which is exactly what the frontpage example did before the split. The
    // corpus teaches the PURE Koru surface, so a split test shows input.k
    // alone; a `.kz`-only test (not yet split) falls back to input.kz.
    // Precondition: input.k must be self-contained (its own const block).
    const inputKzPath = path.join(dir, 'input.kz');
    const inputKPath = path.join(dir, 'input.k');
    // The corpus teaches the PURE Koru surface. A `.kz` is Koru embedded in
    // host text, where every Koru line opens with `~` — the host-boundary
    // marker (frag-tilde-marks-the-host-boundary). Pure Koru (`.k`) rejects
    // the tilde outright, so a reference corpus that prints `~tor`, `~import`,
    // `~hello()` would be teaching a spelling the language refuses: the
    // marker is stripped at line start (the only position it occupies in
    // `.kz`) before embedding. Type-declaration bodies, host Zig, and `~`
    // inside strings are untouched — the strip is exactly the marker, nothing
    // else. Applied to both inputs so a `.k` migrating back the other way is
    // represented the same way.
    const deTilde = (s) => s.split('\n').map((l) => l.replace(/^([ \t]*)~/, '$1')).join('\n');
    const parts = [];
    if (fs.existsSync(inputKPath))
      parts.push(deTilde(fs.readFileSync(inputKPath, 'utf-8')).replace(/\n+$/, ''));
    else if (fs.existsSync(inputKzPath))
      parts.push(deTilde(fs.readFileSync(inputKzPath, 'utf-8')).replace(/\n+$/, ''));
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
