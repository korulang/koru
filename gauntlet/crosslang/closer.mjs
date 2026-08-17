#!/usr/bin/env node
// The cross-language closer — the oracle diff.
//
// Runs the SAME scenario on BOTH sides (Cordis reference + the Koru bridge)
// and diffs them against per-scenario lifecycle invariants. A scenario is a
// shared dynamic-composition property the two runtimes both claim; the closer
// is the machine that checks they agree.
//
// Exit: 0 = every scenario satisfies its invariant on both sides, 1 = a
// violation, 2 = closer infrastructure error.

import { execSync } from 'node:child_process'
import { existsSync, readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

function argValue(flag, def) {
  const i = process.argv.indexOf(flag)
  return i >= 0 && i + 1 < process.argv.length ? process.argv[i + 1] : def
}

const CORDIS = argValue('--cordis-ref', '/Users/larsde/src/cordis-ref')
const KORU = argValue('--koru', '/Users/larsde/src/koru')
const HERE = dirname(fileURLToPath(import.meta.url))

// ---------------------------------------------------------------------------
// Each scenario names a shared theorem. A side is reduced to a list of
// canonical markers plus (when it needs raw structure) the raw trace; the
// check fn returns { ok, a, b, label, shown } for the verdict line.
// ---------------------------------------------------------------------------
const SCENARIOS = [
  {
    id: 'R1-ordering',
    invariant: 'dependent leaves ACTIVE before the provider binding withdraws',
    cordisFixture: 'xlang-r1-cordis.spec.ts',
    koruPin: 'tests/regression/400_RUNTIME_FEATURES/440_RESOURCE_BRIDGE/440_010_guarded_withdrawal',
    name: 'Cordis',
    reduce(raw, side) {
      if (side === 'Cordis') {
        const markers = raw.map(t => {
          if (t.startsWith('fiber|state|2|')) return 'consumer-leaves-active'
          if (t.startsWith('service|withdraw|')) return 'provider-withdraw'
          return null
        }).filter(Boolean)
        const consumer = markers.indexOf('consumer-leaves-active')
        const withdraw = markers.indexOf('provider-withdraw')
        return { ok: consumer > -1 && withdraw > -1 && consumer < withdraw, a: consumer, b: withdraw, shown: markers }
      }
      const markers = raw.map(l => {
        if (l.includes('close-query() ran')) return 'consumer-leaves-active'
        if (l.includes("[BRIDGE] Invoked 'close-file'")) return 'provider-withdraw'
        return null
      }).filter(Boolean)
      const consumer = markers.indexOf('consumer-leaves-active')
      const withdraw = markers.indexOf('provider-withdraw')
      return { ok: consumer > -1 && withdraw > -1 && consumer < withdraw, a: consumer, b: withdraw, shown: markers }
    },
  },
  {
    id: 'R2-exactness',
    invariant: 'each binding withdraws EXACTLY ONCE (inverse applied once)',
    cordisFixture: 'xlang-r2-cordis.spec.ts',
    koruPin: 'tests/regression/400_RUNTIME_FEATURES/440_RESOURCE_BRIDGE/440_013_recovery_exactness',
    name: 'Cordis',
    reduce(raw, side) {
      if (side === 'Cordis') {
        const a = raw.filter(t => t === 'service|withdraw|storeA').length
        const b = raw.filter(t => t === 'service|withdraw|storeB').length
        return { ok: a === 1 && b === 1, a, b, labelA: 'storeA-withdraw#', labelB: 'storeB-withdraw#', shown: [] }
      }
      const a = raw.filter(l => l.includes("close-file() ran for 'a.txt'")).length
      const b = raw.filter(l => l.includes("close-file() ran for 'b.txt'")).length
      return { ok: a === 1 && b === 1, a, b, labelA: 'release:a#', labelB: 'release:b#', shown: [] }
    },
  },
]

// ---------------------------------------------------------------------------
// runners
// ---------------------------------------------------------------------------
function runCordis(fixture) {
  const src = join(HERE, fixture)
  const dst = join(CORDIS, 'packages/core/tests', fixture)
  execSync(`cp ${JSON.stringify(src)} ${JSON.stringify(dst)}`, { stdio: 'pipe' })
  const out = execSync(
    `cd ${CORDIS} && bunx vitest run packages/core/tests/${fixture} --reporter=verbose 2>&1`,
    { stdio: 'pipe', maxBuffer: 10 * 1024 * 1024 },
  ).toString()
  const line = out.split('\n').find(l => l.startsWith('XLANG_CORDIS '))
  if (!line) throw new Error(`no XLANG_CORDIS line in vitest output for ${fixture}:\n` + out.slice(-2000))
  return JSON.parse(line.slice('XLANG_CORDIS '.length))
}

function runKoru(pinDir) {
  let harnessFailed = false
  try {
    execSync(`cd ${KORU} && ./run_single_test.sh ${JSON.stringify(pinDir)}`, {
      stdio: 'pipe',
      maxBuffer: 10 * 1024 * 1024,
    })
  } catch {
    harnessFailed = true
  }
  const actual = join(KORU, pinDir, 'actual.txt')
  if (!existsSync(actual)) return { harnessFailed, lines: [] }
  return { harnessFailed, lines: readFileSync(actual, 'utf-8').split('\n').filter(Boolean) }
}

function reduceScenario(s, raw, side) {
  const r = s.reduce(raw, side)
  r.name = (side === 'Cordis' ? 'Cordis  ' : 'Koru bridge')
  if (s.id === 'R2-exactness' && side === 'Koru bridge') r.name = 'Koru bridge'
  return r
}

// ---------------------------------------------------------------------------
// verdicts
// ---------------------------------------------------------------------------
let verdict = 'PASS'
console.log('== cross-language closer ==')
for (const s of SCENARIOS) {
  let cordisRaw, koru
  try {
    cordisRaw = runCordis(s.cordisFixture)
    koru = runKoru(s.koruPin)
  } catch (err) {
    console.error(`CLOSER ERROR (scenario ${s.id}): ${err.message}`)
    process.exitCode = 2
    process.exit(2)
  }
  const cordisTrace = Array.isArray(cordisRaw) ? cordisRaw : []
  const cRes = reduceScenario(s, cordisTrace, 'Cordis')
  const kRes = reduceScenario(s, koru.lines || [], 'Koru bridge')

  console.log(`--- scenario ${s.id}: ${s.invariant} ---`)
  console.log(`Cordis  trace: ${cordisTrace.length} raw events`)
  console.log(`Koru    trace: ${(koru.lines || []).length} raw lines${koru.harnessFailed ? '  [HARNESS FAILED — substrate caught a violation]' : ''}`)

  for (const r of [cRes, kRes]) {
    const mark = r.ok ? 'PASS' : 'FAIL'
    if (!r.ok) verdict = 'FAIL'
    const la = r.labelA ?? (s.id === 'R1-ordering' ? 'consumer-leaves@' : '')
    const lb = r.labelB ?? la
    console.log(`${mark}  ${r.name} ${la}${r.a} ${lb}${r.b}${(r.shown && r.shown.length) ? `  [${r.shown.join(' > ')}]` : ''}`)
  }
  if (koru.harnessFailed) {
    verdict = 'FAIL'
    console.log('FAIL  Koru bridge  harness rejected the run — substrate caught a violation')
  }
}
console.log(`VERDICT: ${verdict}`)
console.log('invariants: ' + SCENARIOS.map(s => `${s.id}=${s.invariant}`).join(' ; '))
process.exitCode = verdict === 'PASS' ? 0 : 1
