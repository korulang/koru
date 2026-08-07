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
 * PORT DETECTION (2026-08-07): a declaration line does not say whether a proc
 *   is ported. Store and kernel kept ONE `|zig` transform body and branched on
 *   `CompilerEnv.lang` inside it, so the spelling never changed and the map
 *   went on calling `store:new` an unported blocker for 129 tests it already
 *   rendered — and `unlock` ranked that finished port first. Worse, 30 more
 *   transforms emit no host source at all and were counted as debt for being
 *   spelled `|zig`. The predicate now READS THE BODY: see `rendersJs`.
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
// A KEYWORD transform is invoked with no module prefix at all — `~float(T)`,
// not `std/types:float(T)` — so `CALL` never saw one, and every test whose only
// stdlib contact was a keyword landed in `no-stdlib-calls`: declared free of
// stdlib dependency while depending on a transform that emits Zig. That is how
// `115_032` and `115_037` sat on the emitter board as greens, then turned red
// the moment `f9723183` stopped dropping imported-module host lines and
// `const Temperature = f64;` reached node. The failure was always there; the
// map had classified it out of sight.
//
// The spelling is indistinguishable from calling a locally declared tor
// (`~process(value: 10)`), so resolution is gated twice: the name must be a
// keyword tor of an IMPORTED stdlib module, and must NOT be declared in the
// test's own sources. A user tor shadowing a stdlib keyword name resolves to
// the user's, which is also what the compiler does.
const KEYWORD_CALL = /^[^\S\n]*~([a-z][A-Za-z0-9_.-]*)\s*\(/gm
const LOCAL_DECL = /^\s*~?(?:\[[^\]]*\])?\s*(?:pub\s+)?(?:tor|proc)\s+([A-Za-z0-9_.:%-]+)/gm

// A transform proc runs INSIDE the compiler; its body is Zig even when tagged
// `|js` ("produces JS output, body is structurally Zig" — io.kz:1726-1728).
// Porting one means writing a `|js` variant that EMITS JavaScript, and it stays
// in `.kz`. A runtime proc's `|js` body IS JavaScript and belongs in `.kjs`.
// Two different jobs with two different prerequisites; conflating them mis-sizes
// both and invents a contract-extraction dependency the transform half lacks.
const isTransform = (ann) => !!ann && /transform|comptime|keyword/.test(ann)

// A transform proc can be ported to a second target WITHOUT growing a `|js`
// sibling, and store and kernel both did it that way: one body that branches on
// `CompilerEnv.lang` and renders whichever host it is asked for. Judged by
// spelling alone that body is `|zig` and nothing else, so the map called
// `store:new` an unported blocker for 129 tests it had already been ported for
// — over-reporting the remaining work and ranking `unlock` off a port that was
// finished. Reading the body is what tells the two apart.
const LANG_AWARE = /CompilerEnv\.lang/

// The four Item variants that carry HOST SOURCE out of a transform (ast.zig
// :361-379). A transform that constructs none of them contributes no host text
// to the produced program — it rewrites the AST and the emitter renders the
// result — so it cannot block a target no matter how it is spelled. 47 of the
// 75 transform procs in koru_std are this shape, `store:insert` among them,
// and every one was counted as debt.
const HOST_NODE = /ast\.(InlineCode|ProcDecl|HostLine|HostTypeDecl)\b|\.(inline_code|proc_decl|host_line|host_type_decl)\s*=/

// Brace-match a proc body, treating Zig's lexical hiding places as data: `//`
// to end of line, `"…"` and `'…'` with escapes, and — the one that actually
// bit — `\\` multiline strings, where a `}}` in emitted text is two closing
// braces to a naive counter. That exact defect lived in parser.zig until today
// (a8379684); this scanner is the same rule, written once more because it must
// hold here for the census to mean anything.
function procBody(src, from) {
  let i = src.indexOf('{', from)
  if (i < 0) return ''
  const start = i
  let depth = 0
  while (i < src.length) {
    const c = src[i]
    if (c === '/' && src[i + 1] === '/') { i = src.indexOf('\n', i); if (i < 0) break; continue }
    if (c === '\\' && src[i + 1] === '\\') { i = src.indexOf('\n', i); if (i < 0) break; continue }
    if (c === '"' || c === "'") {
      const q = c
      i++
      while (i < src.length && src[i] !== q) { if (src[i] === '\\') i++; i++ }
      i++
      continue
    }
    if (c === '{') depth++
    else if (c === '}' && --depth === 0) return src.slice(start, i + 1)
    i++
  }
  return src.slice(start)
}

// Does this proc put JavaScript in front of the emitter? Three ways, and only
// the first is visible in the declaration line:
//   a `|js` variant           — the spelling the map was built to read
//   a lang-aware `|zig` body  — one body, both hosts (store:new, kernel:init)
//   no host emission at all   — nothing target-specific to render
// Runtime procs are excluded from the last two: their body IS host source
// rather than a program that writes host source, so "constructs no ast.Item"
// is true of every one of them and would mark the whole runtime surface ported.
const rendersJs = (p) => p.langs.has('js') || (p.transform && (p.langAware || !p.emitsHost))

function loadStdlib() {
  const mods = new Map()
  const get = (n) => {
    if (!mods.has(n)) mods.set(n, { name: n, procs: new Map(), tors: new Map(), facets: new Set(), lines: 0 })
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
    // Keep the event's OWN annotation. A proc inherits transform-ness from the
    // event it implements, and the annotation is frequently written there
    // rather than on the proc line: kernel.kz:80 declares
    // `~[comptime|transform|claims_descendants]pub tor init`, and kernel.kz:90
    // then writes a bare `~proc init|zig`. Reading only the proc line tagged
    // kernel:init a portable runtime port worth 27 tests, when it is the
    // Zig-only MLIR/GPU backend that must never be ported at all.
    for (const t of src.matchAll(TOR_DECL)) mod.tors.set(t[2], t[1] || '')
    for (const d of src.matchAll(PROC_DECL)) {
      const [, ann, proc, lang] = d
      if (!mod.procs.has(proc)) mod.procs.set(proc, { langs: new Set(), facets: new Set(), transform: false, emitsHost: false, langAware: false })
      const p = mod.procs.get(proc)
      p.langs.add(lang)
      p.facets.add(ext)
      if (isTransform(ann) || isTransform(mod.tors.get(proc))) p.transform = true
      const body = procBody(src, d.index + d[0].length)
      if (HOST_NODE.test(body)) p.emitsHost = true
      if (LANG_AWARE.test(body)) p.langAware = true
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
// The board is EVIDENCE, not scope: js-scan derives its scope from this map, so
// reading its output back would be circular if it decided what to measure. It
// decides only what NOT to re-litigate. A green row is a proof that survives
// re-measurement — the next scan runs the test again and would demote it — and
// a missing or stale board costs nothing but a static verdict.
const BOARD = join(ROOT, 'test-results/js-scan.json')
const MEASURED_GREEN = new Set()
if (existsSync(BOARD)) {
  try {
    for (const r of JSON.parse(readFileSync(BOARD, 'utf8')).results ?? []) {
      if (r.status === 'js-ok') MEASURED_GREEN.add(r.test)
    }
  } catch { /* an unparseable board is no evidence, not a crash */ }
}


function analyze() {
  const std = loadStdlib()
  const rows = []
  const unresolved = new Map()
  const blockerHits = new Map()

  // name -> [module, …] for every keyword tor in the stdlib. Two modules can
  // own the same keyword (`new` and `stored` are both grid's and store's), so
  // the index is one-to-many and the test's import set picks the owner.
  const keywordOwners = new Map()
  for (const mod of std.values()) {
    for (const [tor, ann] of mod.tors) {
      if (!/keyword/.test(ann)) continue
      if (!keywordOwners.has(tor)) keywordOwners.set(tor, [])
      keywordOwners.get(tor).push(mod.name)
    }
  }

  for (const dir of findTests(TESTS)) {
    const rel = dir.slice(TESTS.length + 1)
    const src = readTestSources(dir)
    const imports = new Set([...src.matchAll(IMPORT)].map((m) => m[1]))
    const calls = new Set([...src.matchAll(CALL)].map((c) => `${c[1]}:${c[2]}`))
    const localNames = new Set([...src.matchAll(LOCAL_DECL)].map((m) => m[1]))
    for (const k of src.matchAll(KEYWORD_CALL)) {
      const name = k[1]
      if (localNames.has(name)) continue
      const owner = (keywordOwners.get(name) || []).find((m) => imports.has(m))
      if (owner) calls.add(`${owner}:${name}`)
    }

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
      if (rendersJs(p)) covered.push(key)
      else if (p.langs.has('zig')) {
        blocked.push(key)
        if (p.transform) needsTransformPort++; else needsRuntimePort++
      } else covered.push(key) // template/raw lowering — host-agnostic
    }

    for (const u of unknown) unresolved.set(u, (unresolved.get(u) || 0) + 1)

    // Order matters. A fixture carrying its own unported `|zig` proc cannot
    // reach the JS emitter's later stages at all, so that verdict outranks any
    // stdlib finding: reporting such a test as "blocked on std/list" would send
    // someone to port list and change nothing.
    const staticBucket =
      localZigOnly.length ? 'blocked-on-test-host'
      : calls.size === 0 ? 'no-stdlib-calls'
      : !touchesRuntime ? 'compile-time-only'
      : unknown.length ? 'unresolved'
      : blocked.length ? 'blocked-on-stdlib'
      : 'ready'

    // A static predicate that contradicts a measurement is wrong, and this one
    // does: `taps:tap` only REWRITES an `inline_code` step it found in the
    // program, so `emitsHost` fires on a pass-through and 24 tests that node
    // runs green were called blocked. Distinguishing "originates host text"
    // from "re-wraps host text it was handed" is not something a regex over the
    // body can do — but it does not have to, because a green run already proves
    // every proc the test reached rendered JavaScript. Where the board has
    // spoken, the map defers to it and says so; where it has not, the static
    // verdict stands and the test gets scanned.
    const demonstrated = MEASURED_GREEN.has(rel) && staticBucket.startsWith('blocked')
    const bucket = demonstrated ? 'ready' : staticBucket

    if (!demonstrated) {
      for (const key of blocked) {
        if (!blockerHits.has(key)) blockerHits.set(key, new Set())
        blockerHits.get(key).add(rel)
      }
    }

    rows.push({ test: rel, bucket, staticBucket, demonstrated, imports: [...imports],
                covered, blocked, unknown, needsTransformPort, needsRuntimePort, localZigOnly })
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
  // How the transform half reaches JS, since "|js sibling" is now only one of
  // three routes and the report should not let the other two hide inside a
  // single total.
  const via = { sibling: 0, langAware: 0, neutral: 0, unported: 0 }
  for (const m of runtimeModules()) {
    for (const p of m.procs.values()) {
      const k = p.transform ? 'transform' : 'runtime'
      if (p.langs.has('zig')) z[k]++
      if (rendersJs(p)) j[k]++
      if (p.langs.has('zig') && rendersJs(p)) both[k]++
      if (!p.transform) continue
      if (p.langs.has('js')) via.sibling++
      else if (p.langAware) via.langAware++
      else if (!p.emitsHost) via.neutral++
      else via.unported++
    }
  }
  return { zig: z, js: j, both, via }
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
console.log('    kind         |zig  renders   unported   what a port means')
console.log(`    runtime   ${String(cov.zig.runtime).padStart(7)} ${String(cov.js.runtime).padStart(8)} ${String(cov.zig.runtime - cov.both.runtime).padStart(10)}   a JS body in a .kjs sibling; no .k extraction needed`)
console.log(`    transform ${String(cov.zig.transform).padStart(7)} ${String(cov.js.transform).padStart(8)} ${String(cov.zig.transform - cov.both.transform).padStart(10)}   a |js variant, or one body that branches on lang`)
console.log(`\n    how the transform half reaches JS:  ${cov.via.sibling} |js sibling · ${cov.via.langAware} lang-aware body · ${cov.via.neutral} emit no host source · ${cov.via.unported} unported`)
console.log('\n  TOP BLOCKING MODULES')
for (const m of moduleRanking().slice(0, 10)) {
  console.log(`    ${m.module.padEnd(18)} blocks ${String(m.tests).padStart(4)}   (${m.sole} solely)   ${m.procs.size} unported procs`)
}
const tPort = rows.reduce((a, r) => a + (!r.demonstrated && r.needsTransformPort > 0 ? 1 : 0), 0)
const rPort = rows.reduce((a, r) => a + (!r.demonstrated && r.needsRuntimePort > 0 ? 1 : 0), 0)
console.log(`\n    tests blocked by a TRANSFORM port   ${tPort}`)
console.log(`    tests blocked by a RUNTIME  port    ${rPort}`)
console.log('\n  INSTRUMENT HONESTY')
console.log(`    unresolved call sites   ${unresolvedTotal}   across ${unresolved.size} distinct names`)
for (const [k, v] of [...unresolved].sort((a, b) => b[1] - a[1]).slice(0, 8)) {
  console.log(`      ${k.padEnd(34)} ${v}`)
}
const shown = rows.filter((r) => r.demonstrated)
console.log(`    static verdict overruled by the board   ${shown.length}   (called blocked, measured green)`)
for (const [k, v] of Object.entries(shown.reduce((a, r) => {
  for (const b of new Set(r.blocked)) a[b] = (a[b] || 0) + 1
  return a
}, {})).sort((a, b) => b[1] - a[1]).slice(0, 5)) {
  console.log(`      ${k.padEnd(34)} ${v}   emits host source only by passing it through`)
}
const frac = (counts.unresolved || 0) / total
console.log(`    verdict: ${
  unresolvedTotal === 0 ? 'clean'
  : frac < 0.05 ? `usable — ${(frac * 100).toFixed(1)}% of tests unclassified`
  : `DO NOT TRUST — ${(frac * 100).toFixed(1)}% of tests unclassified, large enough to move every number above`}`)
console.log('')
