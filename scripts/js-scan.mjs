#!/usr/bin/env node
/**
 * js-scan — measure-only JavaScript-parity sweep.
 *
 * The existing closer (`regression_check_js_equivalence`, regression_lib.sh:270)
 * both MEASURES and GATES: on divergence it deletes SUCCESS, writes FAILURE and
 * decrements the pass count. That fusion is why the JS check has to stay opt-in
 * — flipping `LANGUAGES` on across the corpus would turn ~900 green tests red
 * and destroy the board.
 *
 * This splits the two. js-scan runs the identical check and NEVER touches
 * SUCCESS or FAILURE. It only records. Measuring is how you learn where the
 * frontier is; gating is a promotion a walk decides on afterwards, per koru's
 * own CI-graduation doctrine (an alarm becomes a blocking gate only by explicit
 * decision, never by arriving).
 *
 * Semantics are mirrored from the closer deliberately — same entry resolution,
 * same COMPILER_FLAGS and ARGS passthrough, same trailing-whitespace trim, same
 * timeout, same typed statuses.
 *
 * ONE DELIBERATE DIVERGENCE, and it used to be an undeclared lie in this
 * comment. The real closer runs the JS check only for a test whose ZIG baseline
 * already passed (regression_lib.sh:277). This scan runs it regardless, because
 * "does the emitter produce correct JavaScript" is a fair question even where
 * the Zig target is red. But that means the headline is measured over a
 * population the closer would partly skip — 53 of 222 at the time this was
 * written — so the report SPLITS on the Zig marker. The zig-green figure is the
 * one that predicts the runner; the zig-red figure is real information about the
 * emitter and must never be quietly folded into the same number.
 *
 *   ./scripts/js-scan.mjs                     scan the emitter-testable buckets
 *   ./scripts/js-scan.mjs --sample 30         cheap validation run
 *   ./scripts/js-scan.mjs --bucket all        every positive test
 *   ./scripts/js-scan.mjs --jobs 6            concurrency (default 4)
 */

import { readFileSync, writeFileSync, existsSync, rmSync } from 'node:fs'
import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const execFileAsync = promisify(execFile)
const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..')
const KORUC = join(ROOT, 'zig-out/bin/koruc')
const TIMEOUT = Number(process.env.REGRESSION_TEST_TIMEOUT || 30) * 1000

const argv = process.argv.slice(2)
const flag = (n, d) => { const i = argv.indexOf(n); return i === -1 ? d : argv[i + 1] }
const SAMPLE = Number(flag('--sample', 0))
const JOBS = Number(flag('--jobs', 4))
const BUCKET = flag('--bucket', 'emitter')
const OUT = flag('--out', join(ROOT, 'test-results/js-scan.json'))

// The map is the source of scope. Re-deriving "which tests are emitter-testable"
// here would be a second definition free to drift from the first.
const mapJson = JSON.parse(
  (await execFileAsync('node', [join(ROOT, 'scripts/js-parity-map.mjs'), 'json'], { maxBuffer: 1 << 28 })).stdout,
)
const EMITTER_BUCKETS = new Set(['ready', 'no-stdlib-calls'])
let tests = mapJson.tests.filter((t) =>
  BUCKET === 'all' ? true : BUCKET === 'emitter' ? EMITTER_BUCKETS.has(t.bucket) : t.bucket === BUCKET)

// --cluster narrows to one named failure family from docs/js-parity/clusters.json.
// A contestant fixing one gap needs a seconds-long feedback loop, not the 5-minute
// full sweep; the full sweep is the arbiter's breadth check, run once on the merged
// tree. Same code path either way, so a cluster number and a full-scan number can
// never disagree about the same test.
const CLUSTER = flag('--cluster', null)
if (CLUSTER) {
  const clusters = JSON.parse(readFileSync(join(ROOT, 'docs/js-parity/clusters.json'), 'utf8'))
  const want = clusters[CLUSTER]
  if (!want) {
    console.error(`unknown cluster '${CLUSTER}'. known: ${Object.keys(clusters).join(', ')}`)
    process.exit(2)
  }
  const set = new Set(want)
  tests = mapJson.tests.filter((t) => set.has(t.test))
}
if (SAMPLE > 0) {
  // Deterministic stride, not a random draw: a sample must be reproducible or
  // it cannot be compared against the next one.
  const stride = Math.max(1, Math.floor(tests.length / SAMPLE))
  tests = tests.filter((_, i) => i % stride === 0).slice(0, SAMPLE)
}

// --tests <file>: newline-delimited test paths. The host-fixture wave slices 361
// tests across several contestants, and a slice is not a failure family, so
// --cluster cannot express it. Paths are matched against the map, so a slice
// naming a test that has since changed bucket is reported rather than silently
// dropped — a contestant measuring 40 tests must not be told it measured 38.
const TESTS_FILE = flag('--tests', null)
if (TESTS_FILE) {
  const want = readFileSync(TESTS_FILE, 'utf8').split('\n').map((l) => l.trim()).filter(Boolean)
  const byName = new Map(mapJson.tests.map((t) => [t.test, t]))
  const missing = want.filter((w) => !byName.has(w))
  if (missing.length) {
    console.error(`  ${missing.length} listed test(s) not in the map — first: ${missing[0]}`)
  }
  tests = want.filter((w) => byName.has(w)).map((w) => byName.get(w))
}

// test_entry (regression_lib.sh:77): input.kz when present, else input.k.
function entryOf(dir) {
  return existsSync(join(dir, 'input.kz')) ? join(dir, 'input.kz') : join(dir, 'input.k')
}

function readLines(p) {
  try { return readFileSync(p, 'utf8').split('\n').filter((l) => l.length) } catch { return [] }
}

const trim = (s) => s.split('\n').map((l) => l.replace(/[ \t]+$/, '')).join('\n').replace(/\n+$/, '')

// node prints "<path>:<line>", then the offending source, then the real
// message. Taking the first non-empty line yields the path every time — the one
// part of a stack trace that says nothing about what went wrong.
function firstError(raw) {
  const lines = (raw || '').split('\n').map((l) => l.trim()).filter(Boolean)
  const named = lines.find((l) => /(^|\s)(\w*Error|error\[?\w*\]?|panic)[:\s]/i.test(l))
  return (named || lines[0] || 'failed').slice(0, 200)
}

// The Zig baseline, as the real closer reads it (regression_lib.sh:277):
// SUCCESS present and FAILURE absent. These markers are RUN OUTPUT, not tracked
// files — a worktree that has never run the suite has none of them, and the
// first version of this check read that absence as "red" and cheerfully
// reported 152 zig-red tests. Absence is UNKNOWN, and a report that cannot tell
// unknown from red is worse than one that omits the split.
function zigState(dir) {
  if (existsSync(join(dir, 'FAILURE'))) return 'red'
  if (existsSync(join(dir, 'SUCCESS'))) return 'green'
  return 'unknown'
}

async function scanOne(row) {
  const dir = join(ROOT, 'tests/regression', row.test)
  const started = Date.now()
  const zig = zigState(dir)
  const res = (status, detail) => ({ test: row.test, bucket: row.bucket, zig, status, detail, ms: Date.now() - started })

  const jsOut = join(dir, 'output_emitted.js')
  // A stale artifact from a previous scan would let a compile failure read as a
  // pass. Clear before, not after — an interrupted run leaves the tree clean.
  try { rmSync(jsOut, { force: true }) } catch { /* nothing to clear */ }

  const flags = readLines(join(dir, 'COMPILER_FLAGS')).flatMap((l) => l.trim().split(/\s+/)).filter(Boolean)

  // A timeout is NOT a compile failure, and reporting it as one is how a cold
  // cache reads as a code regression. Merging main invalidated the backend
  // cache; every test then did a full metacircular rebuild, 46 tests hit the
  // 30s wall, and the run showed 121 -> 92 as if a commit had broken something.
  // `killed` distinguishes "we stopped it" from "it failed", so say so.
  try {
    await execFileAsync(KORUC, [entryOf(dir), '--lang=js', ...flags], { cwd: ROOT, timeout: TIMEOUT, maxBuffer: 1 << 26 })
  } catch (e) {
    if (e.killed || e.signal === 'SIGTERM') {
      return res('js-timeout', `koruc exceeded ${TIMEOUT / 1000}s (cold cache? raise REGRESSION_TEST_TIMEOUT)`)
    }
    return res('js-compile', firstError(e.stderr || e.message))
  }

  let emitted
  try { emitted = readFileSync(jsOut, 'utf8') } catch { return res('js-noemit', 'no output_emitted.js') }
  if (!emitted.trim()) return res('js-noemit', 'output_emitted.js is empty')

  const args = readLines(join(dir, 'ARGS'))
  let stdout
  try {
    const r = await execFileAsync('node', [jsOut, ...args], { cwd: dir, timeout: TIMEOUT, maxBuffer: 1 << 26 })
    stdout = r.stdout + r.stderr
  } catch (e) {
    return res('js-runtime', firstError(e.stderr || e.message))
  }

  const expected = trim(readFileSync(join(dir, 'expected.txt'), 'utf8'))
  const actual = trim(stdout)
  if (expected !== actual) {
    const el = expected.split('\n'), al = actual.split('\n')
    const i = el.findIndex((l, k) => l !== al[k])
    return res('js-mismatch', `line ${i + 1}: expected ${JSON.stringify(el[i] ?? '')} got ${JSON.stringify(al[i] ?? '')}`)
  }
  return res('js-ok', '')
}

// Bounded worker pool. Each koruc --lang=js drives the metacircular backend,
// which itself shells out to zig build against a shared cache; unbounded
// fan-out contends on that cache rather than going faster.
async function run(items, jobs) {
  const out = []
  let next = 0
  let done = 0
  const workers = Array.from({ length: Math.min(jobs, items.length) }, async () => {
    while (next < items.length) {
      const row = items[next++]
      out.push(await scanOne(row))
      done++
      if (done % 25 === 0 || done === items.length) {
        process.stderr.write(`  scanned ${done}/${items.length}\n`)
      }
    }
  })
  await Promise.all(workers)
  return out
}

// Failure families, DERIVED from this run rather than hand-maintained.
//
// The first clusters.json was written by hand off the 45/220 baseline. Two
// contestants later the failure distribution had changed completely and that
// file described a population that no longer existed — a stale fan-out map is
// worse than none, because it dispatches confident work at a gap someone
// already closed. So a full emitter-bucket scan rewrites it, every time, and
// the map can only ever describe the run that produced it.
//
// Grouped on a normalised cause: panics lose their thread id, numbers collapse,
// so `NoJsProcBody` from two tests lands in one family while two genuinely
// different KORU errors stay apart. Families under `minSize` are left out — a
// cluster of one is a bug report, not a work unit.
function deriveClusters(results, minSize = 3) {
  const norm = (d) => (d || '')
    .replace(/thread \d+ panic: /, '')
    .replace(/\/[^\s'"]+\//g, '')          // absolute paths differ per worktree
    .replace(/\b\d+\b/g, 'N')
    .slice(0, 90)
  const groups = new Map()
  for (const r of results) {
    if (r.status === 'js-ok') continue
    const key = `${r.status} | ${norm(r.detail)}`
    if (!groups.has(key)) groups.set(key, [])
    groups.get(key).push(r.test)
  }
  const slug = (s) => s.toLowerCase().replace(/[^a-z0-9]+/g, '_').replace(/^_+|_+$/g, '').slice(0, 44)
  const out = {}
  const meta = []
  let i = 0
  for (const [key, tests] of [...groups].sort((a, b) => b[1].length - a[1].length)) {
    if (tests.length < minSize) continue
    const [status, cause] = key.split(' | ')
    const name = `${String.fromCharCode(65 + i++)}_${slug(cause) || status}`
    out[name] = tests
    meta.push({ name, status, cause, count: tests.length })
  }
  return { clusters: out, meta }
}

console.error(`\n  js-scan — ${tests.length} tests, ${JOBS} jobs, measure-only (SUCCESS/FAILURE untouched)\n`)
const t0 = Date.now()
const results = await run(tests, JOBS)
const wall = ((Date.now() - t0) / 1000).toFixed(1)

const byStatus = {}
for (const r of results) byStatus[r.status] = (byStatus[r.status] || 0) + 1

// Cluster = the top-level regression category (000_CORE_LANGUAGE, …). It is the
// axis the suite is already organised on, so a histogram along it points at a
// place in the tree rather than at an abstraction.
const byCluster = {}
for (const r of results) {
  const c = r.test.split('/')[0]
  byCluster[c] ??= { total: 0, ok: 0 }
  byCluster[c].total++
  if (r.status === 'js-ok') byCluster[c].ok++
}

writeFileSync(OUT, JSON.stringify({
  generated: new Date().toISOString(), bucket: BUCKET, sample: SAMPLE || null,
  wallSeconds: Number(wall), byStatus, byCluster, results,
}, null, 2))

// Only a FULL emitter-bucket run may rewrite the families. A --cluster run sees
// one family by construction and a --sample run sees a slice; letting either
// rewrite the map would shrink it to whatever was last looked at.
let derived = null
if (BUCKET === 'emitter' && !SAMPLE && !CLUSTER) {
  derived = deriveClusters(results)
  writeFileSync(join(ROOT, 'docs/js-parity/clusters.json'), JSON.stringify(derived.clusters, null, 2))
  writeFileSync(join(ROOT, 'docs/js-parity/clusters-meta.json'), JSON.stringify({
    generated: new Date().toISOString(), scanned: results.length,
    passing: results.filter((r) => r.status === 'js-ok').length, families: derived.meta,
  }, null, 2))
}

if (derived) {
  console.log('\n  DERIVED FAMILIES  (docs/js-parity/clusters.json rewritten)')
  for (const f of derived.meta) {
    console.log(`    ${String(f.count).padStart(4)}  ${f.name}`)
    console.log(`          ${f.cause.slice(0, 88)}`)
  }
  const covered = derived.meta.reduce((a, f) => a + f.count, 0)
  const failures = results.length - (byStatus['js-ok'] || 0)
  console.log(`\n    ${covered} of ${failures} failures fall in a family of 3+; ${failures - covered} are singletons`)
}

// The zig-green figure is what the real gate would report; zig-red is emitter
// progress on tests the gate never reaches. They answer different questions and
// are never averaged. When the markers are absent the split is simply
// unavailable, and the report says that rather than inventing a state.
const ok = byStatus['js-ok'] || 0
const pct = (a, b) => (b ? ((a / b) * 100).toFixed(1) + '%' : '—')
const part = (s) => {
  const rows = results.filter((r) => r.zig === s)
  return { n: rows.length, ok: rows.filter((r) => r.status === 'js-ok').length }
}
const g = part('green'), rd = part('red'), unk = part('unknown')
console.log(`\n  RESULT   ${ok}/${results.length} pass JS equivalence   (${pct(ok, results.length)})   ${wall}s wall`)
if (unk.n === results.length) {
  console.log('    zig baseline UNKNOWN for every test — SUCCESS/FAILURE markers are')
  console.log('    run output, and this tree has not run the suite. Run it here to')
  console.log('    split this number into "what the closer would report" vs "emitter')
  console.log('    correct on tests the closer never reaches".\n')
} else {
  console.log(`    zig-green    ${String(g.ok).padStart(4)}/${String(g.n).padEnd(4)}  ${pct(g.ok, g.n).padStart(6)}   <- what the real closer would report`)
  console.log(`    zig-red      ${String(rd.ok).padStart(4)}/${String(rd.n).padEnd(4)}  ${pct(rd.ok, rd.n).padStart(6)}   <- emitter correct where the closer never runs`)
  if (unk.n) console.log(`    zig-unknown  ${String(unk.ok).padStart(4)}/${String(unk.n).padEnd(4)}  ${pct(unk.ok, unk.n).padStart(6)}   <- no marker; suite not run for these`)
  console.log('')
}
console.log('  BY STATUS')
for (const [k, v] of Object.entries(byStatus).sort((a, b) => b[1] - a[1])) {
  console.log(`    ${k.padEnd(14)} ${String(v).padStart(5)}   ${((v / results.length) * 100).toFixed(1).padStart(5)}%`)
}
console.log('\n  BY CLUSTER')
for (const [c, v] of Object.entries(byCluster).sort((a, b) => b[1].total - a[1].total)) {
  console.log(`    ${c.padEnd(26)} ${String(v.ok).padStart(4)}/${String(v.total).padEnd(4)}  ${((v.ok / v.total) * 100).toFixed(0)}%`)
}
const fails = results.filter((r) => r.status !== 'js-ok')
if (fails.length) {
  console.log('\n  FIRST FAILURES')
  for (const f of fails.slice(0, 12)) {
    console.log(`    ${f.status.padEnd(13)} ${f.test}`)
    if (f.detail) console.log(`      ${f.detail.slice(0, 150)}`)
  }
}
console.log(`\n  full results: ${OUT}\n`)
