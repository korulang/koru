#!/usr/bin/env node
/**
 * js-parity-map — static frontier map for Koru's JavaScript target.
 *
 * Answers, WITHOUT running the suite: for every positive regression test, does
 * the stdlib surface it actually calls have `|js` proc bodies? A test whose
 * reachable surface is fully ported is a real EMITTER test — if it fails, the
 * emitter is wrong. A test reaching an unported proc is blocked on the STDLIB,
 * and reporting it as an emitter failure would be an instrument telling a lie.
 * Separating those two populations is the entire point of this file.
 *
 * The map is DERIVED, never hand-maintained (same discipline as the challenge
 * registry and the hub): re-run it and it re-grounds against the tree.
 *
 * It self-reports its blind spots. Every call it cannot resolve to a declared
 * proc is counted and shown, and the verdict line refuses to endorse its own
 * numbers when that tail is large. A map that quietly rounds down is worse than
 * no map.
 *
 * FACET RULE (ruled 2026-08-06, grounded in koru_std/io.kz:1726-1728):
 *   The facet is chosen by the BODY'S HOST LANGUAGE, never by the target tag.
 *   A [comptime|transform] proc's body is always Zig even when tagged `|js`
 *   ("produces JS output, body is structurally Zig"), so it stays in `.kz`.
 *   Only a runtime proc whose body is literally JavaScript belongs in `.kjs`.
 *
 *   ./scripts/js-parity-map.mjs           human report
 *   ./scripts/js-parity-map.mjs unlock    ranked port-this-next list
 *   ./scripts/js-parity-map.mjs split     contract-extraction (phase 1) sizing
 *   ./scripts/js-parity-map.mjs json      machine-readable
 */

import { readdirSync, readFileSync, existsSync, writeFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..')
const STD = join(ROOT, 'koru_std')
const TESTS = join(ROOT, 'tests/regression')

// Metacircular pipeline modules run at COMPILE time, inside koruc's own
// backend. A user program never dispatches into them at runtime, so a missing
// `|js` body here is correct rather than debt. Counting them would invent a
// mountain nobody has to climb.
const COMPILE_TIME = new Set([
  'compiler', 'compiler_visitor', 'compiler_context', 'compiler_types',
  'parser', 'interpreter', 'build', 'build_defaults', 'deps', 'eval',
  'declarations', 'emitter', 'optimizer', 'ast_dump', 'package',
])

// Declarations may carry an annotation prefix between `~` and the keyword:
//   ~proc all|zig                      runtime proc — body is host source
//   ~[transform]proc new|zig           COMPTIME transform — body is always Zig
//   ~[keyword|comptime|transform]pub tor new
// Missing that prefix silently drops every transform-based module (store's ten
// procs, regex:match, kernel:shape) into the unresolved tail — which is exactly
// what this map's first run did, at 29% unclassified.
const PROC_DECL = /^\s*~?(\[[^\]]*\])?\s*(?:pub\s+)?proc\s+([A-Za-z0-9_.:%-]+)\|([a-z_]+)/gm
const TOR_DECL = /^\s*~?(\[[^\]]*\])?\s*(?:pub\s+)?tor\s+([A-Za-z0-9_.:%-]+)/gm
const IMPORT = /^\s*~?import\s+std\/([A-Za-z0-9_-]+)/gm
// An invocation, not a mere reference. `std/string:String<view>` is a TYPE and
// `*String<view|instance>` a generic parameter list — both matched the older
// bare form and landed in the unresolved tail as phantom "calls". Requiring the
// open paren is what distinguishes calling a proc from naming a type.
const CALL = /\bstd[/.]([A-Za-z0-9_-]+):([A-Za-z0-9_.%-]+)\s*\(/g
// Same shape without the paren — counted only so the map can report how much it
// deliberately ignored, rather than silently discarding it.
const REFERENCE = /\bstd[/.]([A-Za-z0-9_-]+):([A-Za-z0-9_.%-]+)(?!\s*\()/g

// A transform proc runs INSIDE the compiler; its body is Zig even when tagged
// `|js` ("produces JS output, body is structurally Zig" — io.kz:1726-1728).
// Porting one means writing a `|js` variant that EMITS JavaScript, and it stays
// in `.kz`. A runtime proc's `|js` body IS JavaScript and belongs in `.kjs`.
// Two different jobs with two different prerequisites; conflating them mis-sizes
// both and invents a contract-extraction dependency the transform half lacks.
const isTransform = (ann) => !!ann && /transform|comptime|keyword/.test(ann)

function loadStdlib() {
  const mods = new Map()
  const get = (n) => {
    if (!mods.has(n)) mods.set(n, { name: n, procs: new Map(), tors: new Set(), facets: new Set(), lines: 0 })
    return mods.get(n)
  }
  for (const f of readdirSync(STD)) {
    const m = f.match(/^(.+)\.(kz|k|kjs)$/)
    if (!m) continue
    const [, name, ext] = m
    const src = readFileSync(join(STD, f), 'utf8')
    const mod = get(name)
    mod.facets.add(ext)
    if (ext === 'kz') mod.lines = src.split('\n').length
    for (const t of src.matchAll(TOR_DECL)) mod.tors.add(t[2])
    for (const [, ann, proc, lang] of src.matchAll(PROC_DECL)) {
      if (!mod.procs.has(proc)) mod.procs.set(proc, { langs: new Set(), facets: new Set(), transform: false })
      const p = mod.procs.get(proc)
      p.langs.add(lang)
      p.facets.add(ext)
      if (isTransform(ann)) p.transform = true
    }
  }
  return mods
}

// Scope mirrors the closer's own gate (regression_lib.sh:275-282): positive
// MUST_RUN tests with an expected.txt, EXPECT_TRAP excluded. Keeping the two
// denominators identical is what lets this map predict that runner's output.
function findTests(dir, out = []) {
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    if (!e.isDirectory()) continue
    const p = join(dir, e.name)
    if (existsSync(join(p, 'MUST_RUN')) && existsSync(join(p, 'expected.txt')) &&
        !existsSync(join(p, 'EXPECT_TRAP'))) out.push(p)
    findTests(p, out)
  }
  return out
}

const GENERATED = /^(output_emitted|backend|build|build_backend|compiler_env|program_ast|intermediate)/

function readTestSources(dir) {
  let src = ''
  for (const f of readdirSync(dir)) {
    if (!/\.(k|kz|kjs)$/.test(f) || GENERATED.test(f)) continue
    try { src += readFileSync(join(dir, f), 'utf8') + '\n' } catch { /* unreadable facet */ }
  }
  return src
}

function analyze() {
  const std = loadStdlib()
  const rows = []
  const unresolved = new Map()
  const blockerHits = new Map()

  for (const dir of findTests(TESTS)) {
    const rel = dir.slice(TESTS.length + 1)
    const src = readTestSources(dir)
    const imports = new Set([...src.matchAll(IMPORT)].map((m) => m[1]))
    const calls = new Set([...src.matchAll(CALL)].map((c) => `${c[1]}:${c[2]}`))

    // A test's OWN host bodies. The stdlib is not the only place `|zig` lives:
    // an `input.kz` fixture carries its own procs, and the JS emitter aborts
    // with NoJsProcBody on the first one lacking a `|js` sibling. Omitting this
    // is what let the first scan classify 346 tests as emitter-testable when
    // they cannot compile to JS at all until the fixture is split .k/.kz/.kjs —
    // the same facet split the stdlib needs, applied to the corpus.
    const localProcs = new Map()
    for (const [, ann, proc, lang] of src.matchAll(PROC_DECL)) {
      if (isTransform(ann)) continue // a fixture transform emits, it is not emitted
      if (!localProcs.has(proc)) localProcs.set(proc, new Set())
      localProcs.get(proc).add(lang)
    }
    const localZigOnly = [...localProcs.entries()]
      .filter(([, langs]) => langs.has('zig') && !langs.has('js'))
      .map(([p]) => p)

    const covered = [], blocked = [], unknown = []
    let touchesRuntime = false
    let needsTransformPort = 0, needsRuntimePort = 0

    for (const key of calls) {
      const [modName, procName] = key.split(':')
      if (COMPILE_TIME.has(modName)) continue
      touchesRuntime = true
      const mod = std.get(modName)
      if (!mod) { unknown.push(key); continue }
      const p = mod.procs.get(procName)
      if (!p) {
        // Declared as an event but carrying no proc body in this module — a
        // `[norun]` shape marker (kernel:shape), or an event whose lowering is
        // generated elsewhere. There is no Zig body here, so there is nothing
        // Zig-specific to port: host-agnostic, not a blocker. Only a proc that
        // HAS a `|zig` body and LACKS a `|js` one blocks the JS target.
        if (mod.tors.has(procName)) { covered.push(key); continue }
        unknown.push(key)
        continue
      }
      if (p.langs.has('js')) covered.push(key)
      else if (p.langs.has('zig')) {
        blocked.push(key)
        if (p.transform) needsTransformPort++; else needsRuntimePort++
        if (!blockerHits.has(key)) blockerHits.set(key, new Set())
        blockerHits.get(key).add(rel)
      } else covered.push(key) // template/raw lowering — host-agnostic
    }

    for (const u of unknown) unresolved.set(u, (unresolved.get(u) || 0) + 1)

    // Order matters. A fixture carrying its own unported `|zig` proc cannot
    // reach the JS emitter's later stages at all, so that verdict outranks any
    // stdlib finding: reporting such a test as "blocked on std/list" would send
    // someone to port list and change nothing.
    const bucket =
      localZigOnly.length ? 'blocked-on-test-host'
      : calls.size === 0 ? 'no-stdlib-calls'
      : !touchesRuntime ? 'compile-time-only'
      : unknown.length ? 'unresolved'
      : blocked.length ? 'blocked-on-stdlib'
      : 'ready'

    rows.push({ test: rel, bucket, imports: [...imports], covered, blocked, unknown,
                needsTransformPort, needsRuntimePort, localZigOnly })
  }
  return { std, rows, unresolved, blockerHits }
}

const { std, rows, unresolved, blockerHits } = analyze()
const total = rows.length
const unresolvedTotal = [...unresolved.values()].reduce((a, b) => a + b, 0)

const counts = {}
for (const r of rows) counts[r.bucket] = (counts[r.bucket] || 0) + 1

function runtimeModules() {
  return [...std.values()].filter((m) => !COMPILE_TIME.has(m.name) && m.procs.size)
}

// Two populations, deliberately never summed into one "stdlib coverage" number.
// A runtime proc needs a JavaScript body in a `.kjs` facet, which first needs
// the module's contract extracted into `.k`. A transform proc needs a `|js`
// variant that emits JS, written in Zig, staying in `.kz` — no facet split, no
// contract extraction, different skill. One number over both would hide that
// the prerequisite chain applies to only one of them.
function coverage() {
  const z = { runtime: 0, transform: 0 }
  const j = { runtime: 0, transform: 0 }
  const both = { runtime: 0, transform: 0 }
  for (const m of runtimeModules()) {
    for (const p of m.procs.values()) {
      const k = p.transform ? 'transform' : 'runtime'
      if (p.langs.has('zig')) z[k]++
      if (p.langs.has('js')) j[k]++
      if (p.langs.has('zig') && p.langs.has('js')) both[k]++
    }
  }
  return { zig: z, js: j, both }
}

// A blocked test needs EVERY blocker ported. `hits` = how many blocked tests
// touch this proc at all; `frees` = how many it is the LAST blocker for. They
// answer different questions and ranking on the wrong one wastes a port.
function unlockRanking() {
  const out = []
  for (const [proc, tests] of blockerHits) {
    let frees = 0
    for (const r of rows) {
      if (r.bucket === 'blocked-on-stdlib' && r.blocked.length === 1 && r.blocked[0] === proc) frees++
    }
    out.push({ proc, hits: tests.size, frees })
  }
  return out.sort((a, b) => b.hits - a.hits || b.frees - a.frees)
}

function moduleRanking() {
  const by = new Map()
  for (const r of rows) {
    if (r.bucket !== 'blocked-on-stdlib') continue
    const mods = new Set(r.blocked.map((b) => b.split(':')[0]))
    for (const m of mods) {
      if (!by.has(m)) by.set(m, { module: m, tests: 0, sole: 0, procs: new Set() })
      by.get(m).tests++
      if (mods.size === 1) by.get(m).sole++
    }
    for (const b of r.blocked) by.get(b.split(':')[0]).procs.add(b.split(':')[1])
  }
  return [...by.values()].sort((a, b) => b.sole - a.sole || b.tests - a.tests)
}

const mode = process.argv[2] || 'report'

if (mode === 'json') {
  // writeFileSync to fd 1, not console.log + process.exit. On a pipe,
  // console.log is asynchronous and process.exit() discards whatever has not
  // flushed — this payload truncated at exactly 64 KB when js-scan first read
  // it, producing a JSON parse error rather than a short read anyone would
  // recognise as truncation. Synchronous write, natural exit.
  writeFileSync(1, JSON.stringify({
    generated: new Date().toISOString(), buckets: counts, coverage: coverage(),
    unlock: unlockRanking(), modules: moduleRanking().map((m) => ({ ...m, procs: [...m.procs] })),
    unresolved: [...unresolved].sort((a, b) => b[1] - a[1]), tests: rows,
  }, null, 2))
  // Safe here: the write above already completed synchronously.
  process.exit(0)
}

if (mode === 'split') {
  const rt = runtimeModules().sort((a, b) => b.lines - a.lines)
  const done = rt.filter((m) => m.facets.has('k'))
  const todo = rt.filter((m) => !m.facets.has('k'))
  console.log(`\n  PHASE 1 — contract extraction (.kz → .k + .kz), runtime modules only\n`)
  console.log(`    already split   ${done.length}   ${done.map((m) => m.name).join(', ') || '—'}`)
  console.log(`    to split        ${todo.length}   ${todo.reduce((a, m) => a + m.lines, 0).toLocaleString()} lines\n`)
  console.log('    MODULE                 lines   procs   has .kjs')
  for (const m of todo) {
    console.log(`    ${m.name.padEnd(20)} ${String(m.lines).padStart(7)} ${String(m.procs.size).padStart(7)}   ${m.facets.has('kjs') ? 'yes' : ''}`)
  }
  console.log('')
  process.exit(0)
}

if (mode === 'unlock') {
  console.log('\n  RANKED PORT ORDER — runtime modules only\n')
  console.log('    MODULE               blocks   sole   unported procs')
  for (const m of moduleRanking().slice(0, 15)) {
    console.log(`    ${m.module.padEnd(20)} ${String(m.tests).padStart(6)} ${String(m.sole).padStart(6)}   ${m.procs.size}`)
  }
  console.log('\n    PROC                            reaches   alone frees')
  for (const u of unlockRanking().slice(0, 20)) {
    console.log(`    ${u.proc.padEnd(32)} ${String(u.hits).padStart(7)} ${String(u.frees).padStart(12)}`)
  }
  console.log('')
  process.exit(0)
}

const cov = coverage()
console.log(`\n  Koru → JavaScript parity frontier        ${total} positive tests in scope\n`)
console.log('  TEST BUCKETS')
for (const [k, v] of Object.entries(counts).sort((a, b) => b[1] - a[1])) {
  console.log(`    ${k.padEnd(22)} ${String(v).padStart(5)}   ${((v / total) * 100).toFixed(1).padStart(5)}%`)
}
console.log('\n  STDLIB PROC SURFACE  (compile-time pipeline modules excluded)')
console.log('    kind         |zig    |js   unported   what a port means')
console.log(`    runtime   ${String(cov.zig.runtime).padStart(7)} ${String(cov.js.runtime).padStart(6)} ${String(cov.zig.runtime - cov.both.runtime).padStart(10)}   a JS body in a .kjs facet (needs .k contract first)`)
console.log(`    transform ${String(cov.zig.transform).padStart(7)} ${String(cov.js.transform).padStart(6)} ${String(cov.zig.transform - cov.both.transform).padStart(10)}   a |js variant emitting JS, stays in .kz`)
console.log('\n  TOP BLOCKING MODULES')
for (const m of moduleRanking().slice(0, 10)) {
  console.log(`    ${m.module.padEnd(18)} blocks ${String(m.tests).padStart(4)}   (${m.sole} solely)   ${m.procs.size} unported procs`)
}
const tPort = rows.reduce((a, r) => a + (r.needsTransformPort > 0 ? 1 : 0), 0)
const rPort = rows.reduce((a, r) => a + (r.needsRuntimePort > 0 ? 1 : 0), 0)
console.log(`\n    tests blocked by a TRANSFORM port   ${tPort}`)
console.log(`    tests blocked by a RUNTIME  port    ${rPort}`)
console.log('\n  INSTRUMENT HONESTY')
console.log(`    unresolved call sites   ${unresolvedTotal}   across ${unresolved.size} distinct names`)
for (const [k, v] of [...unresolved].sort((a, b) => b[1] - a[1]).slice(0, 8)) {
  console.log(`      ${k.padEnd(34)} ${v}`)
}
const frac = (counts.unresolved || 0) / total
console.log(`    verdict: ${
  unresolvedTotal === 0 ? 'clean'
  : frac < 0.05 ? `usable — ${(frac * 100).toFixed(1)}% of tests unclassified`
  : `DO NOT TRUST — ${(frac * 100).toFixed(1)}% of tests unclassified, large enough to move every number above`}`)
console.log('')
