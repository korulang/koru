#!/usr/bin/env node
// The cross-language closer — rung R1.
//
// Runs the same dynamic-composition scenario on BOTH sides and diffs them
// against one shared lifecycle invariant:
//
//   dependent leaves ACTIVE strictly before the provider's binding withdraws
//
// The order of DISPOSER callbacks is an implementation detail and differs
// between the runtimes (measured). The invariant is stated at the lifecycle
// level, which is what Cordis Theorem 63 actually asserts.
//
// Usage:
//   node gauntlet/crosslang/closer.mjs [--cordis-ref <path>] [--koru <path>]
//
// Exit: 0 = both sides satisfy the invariant (verdict printed), nonzero = a
// side violated it.

import { execSync } from 'node:child_process'
import { existsSync, readFileSync } from 'node:fs'
import { join } from 'node:path'

const CORDIS = process.argv.find((a, i) => a === '--cordis-ref' ? process.argv[i + 1] : null)
  ?? '/Users/larsde/src/cordis-ref'
const KORU = process.argv.find((a, i) => a === '--koru' ? process.argv[i + 1] : null)
  ?? '/Users/larsde/src/koru'

const fixture = join(KORU, 'gauntlet/crosslang/xlang-r1-cordis.spec.ts')
const koruTest = join(
  KORU,
  'tests/regression/400_RUNTIME_FEATURES/440_RESOURCE_BRIDGE/440_010_guarded_withdrawal',
)

function runCordis() {
  const dst = join(CORDIS, 'packages/core/tests/xlang-r1-cordis.spec.ts')
  execSync(`cp ${JSON.stringify(fixture)} ${JSON.stringify(dst)}`, { stdio: 'pipe' })
  const out = execSync(
    `cd ${CORDIS} && bunx vitest run packages/core/tests/xlang-r1-cordis.spec.ts --reporter=verbose 2>&1`,
    { stdio: 'pipe', maxBuffer: 10 * 1024 * 1024 },
  ).toString()
  const line = out.split('\n').find(l => l.startsWith('XLANG_CORDIS '))
  if (!line) throw new Error('no XLANG_CORDIS line in vitest output:\n' + out.slice(-2000))
  return JSON.parse(line.slice('XLANG_CORDIS '.length))
}

function runKoru() {
  // The bridge test must actually pass under the harness (its expected.txt
  // pins dependent-first order). If the harness fails it, the substrate
  // ALREADY caught the violation — we return the marker verdict and let the
  // closer report it, never throw.
  let harnessOut = ''
  let harnessFailed = false
  try {
    execSync(`cd ${KORU} && ./run_single_test.sh ${JSON.stringify(koruTest)}`, {
      stdio: 'pipe',
      maxBuffer: 10 * 1024 * 1024,
    })
  } catch (err) {
    harnessFailed = true
    harnessOut = String(err.stdout ?? '')
  }
  const actual = join(koruTest, 'actual.txt')
  if (!existsSync(actual)) {
    return { harnessFailed, harnessOut, lines: [] }
  }
  return { harnessFailed, harnessOut, lines: readFileSync(actual, 'utf-8').split('\n').filter(Boolean) }
}

// Map a Cordis lifecycle event to a canonical marker, or null.
function cordisEvent(e) {
  if (e.startsWith('fiber|state|2|')) return 'consumer-leaves-active'
  if (e.startsWith('service|withdraw|')) return 'provider-withdraw'
  return null
}

// Map a Koru bridge trace line to a canonical marker, or null.
function koruEvent(line) {
  if (line.includes("close-query() ran")) return 'consumer-leaves-active'
  if (line.includes("[BRIDGE] Invoked 'close-file'")) return 'provider-withdraw'
  return null
}

function check(events, map, name) {
  const canonical = events.map(map).filter(Boolean)
  const consumer = canonical.indexOf('consumer-leaves-active')
  const withdraw = canonical.indexOf('provider-withdraw')
  const ok = consumer > -1 && withdraw > -1 && consumer < withdraw
  return { name, consumer, withdraw, ok, canonical }
}

let verdict = 'PASS'
try {
  const cordis = runCordis()
  const koru = runKoru()
  const c = check(cordis, cordisEvent, 'Cordis')
  const k = check(koru.lines || [], koruEvent, 'Koru bridge')

  console.log('== cross-language closer, rung R1 ==')
  console.log(`Cordis  trace: ${cordis.length} raw events`)
  console.log(`Koru    trace: ${(koru.lines || []).length} raw lines${koru.harnessFailed ? '  [HARNESS FAILED — substrate caught a violation]' : ''}`)
  for (const r of [c, k]) {
    const mark = r.ok ? 'PASS' : 'FAIL'
    if (!r.ok) verdict = 'FAIL'
    console.log(
      `${mark}  ${r.name.padEnd(10)} consumer-leaves@${r.consumer} provider-withdraw@${r.withdraw}  [${r.canonical.join(' > ')}]`,
    )
  }
  if (koru.harnessFailed) {
    verdict = 'FAIL'
    console.log('FAIL  Koru bridge  harness rejected the run — 440_010 expected.txt mismatch (violation caught at substrate)')
  }
  console.log(`VERDICT: ${verdict}`)
  console.log('invariant: dependent leaves ACTIVE before provider binding withdraws')
  process.exitCode = verdict === 'PASS' ? 0 : 1
} catch (err) {
  console.error('CLOSER ERROR:', err.message)
  process.exitCode = 2
}