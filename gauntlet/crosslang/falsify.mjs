#!/usr/bin/env node
// The falsification battery — the closest-without-flattery check, batched.
//
// Runs the cross-language closer against every recorded violation probe in
// ONE scripted pass, so a "cannot be flattered" claim costs one command, one
// backend rebuild per probe, and one guaranteed restore — never the full
// board. Full uncached sweeps are for the publish ceremony, not per-rung.
//
// Probes live in ./probes/*.patch and each edits koru_std/interpreter.kz's
// discharge loop. The expected verdict is the probe's own contract:
//   - The ONE real violation (flat forward + no guard) must go FAIL.
//   - The near-misses (guard-alone, LIFO-alone) must stay PASS.
//   A probe that doesn't meet its contract exits 1 — the battery cannot be
//   flattered, and it can never be left with a dirty tree.
//
// Usage:
//   node gauntlet/crosslang/falsify.mjs [--closer <path>] [--koru <path>]
//
// Exit codes:
//   0 = every probe met its contract and the tree was restored byte-identical
//   1 = a probe failed its contract (violation PASSed, or near-miss FAILed)
//   2 = infrastructure error / dirty tree / patch would not apply clean
//   Signalling the very process refuses to end with interpreter.kz modified.

import { execSync } from 'node:child_process'
import { existsSync, readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = dirname(fileURLToPath(import.meta.url))
const KORU = process.argv.find((a, i) => a === '--koru') ? process.argv[process.argv.indexOf('--koru') + 1] : '/Users/larsde/src/koru'
const CLOSER = process.argv.find((a, i) => a === '--closer') ? process.argv[process.argv.indexOf('--closer') + 1] : join(HERE, 'closer.mjs')
const INTERP = join(KORU, 'koru_std/interpreter.kz')
const PROBE_DIR = join(HERE, 'probes')

// Probe contract: { id, patch, expect: 'PASS'|'FAIL', why }
const BATTERY = [
  { id: 'A-flat',      patch: 'probe-A-flat.patch',      expect: 'FAIL',
    why: 'pre-R1 flat release (forward walk, no guard) — the one real violation' },
  { id: 'B-guardless', patch: 'probe-B-guardless-lifo.patch', expect: 'PASS',
    why: 'LIFO carries ordering even with the guard removed (near-miss, must NOT fire)' },
  { id: 'C-forward',   patch: 'probe-C-forward-guard.patch', expect: 'PASS',
    why: 'guard alone enforces ordering in forward walk (near-miss, must NOT fire)' },
]

function sh(cmd, opts = {}) {
  return execSync(cmd, { stdio: 'pipe', maxBuffer: 64 * 1024 * 1024, ...opts }).toString()
}

function gitStatus(path) {
  // returns true if the file has any difference from HEAD
  try { sh(`git -C ${JSON.stringify(KORU)} diff --quiet -- ${JSON.stringify(join('.', path))}`); return false }
  catch { return true }
}

function runCloser() {
  // The closer exits 1 on a FAIL verdict — that's a *legitimate outcome*, not
  // an infra error. Capture stdout on any exit so we can read the verdict.
  let out = ''
  try {
    out = sh(`node ${JSON.stringify(CLOSER)} --koru ${JSON.stringify(KORU)}`, { stdio: 'pipe' })
  } catch (e) {
    out = String(e.stdout ?? '')
    if (!out) throw e
  }
  const m = /VERDICT:\s*(PASS|FAIL)/.exec(out)
  if (!m) { const err = new Error('closer produced no verdict:\n' + out.slice(-2000)); err.code = 2; throw err }
  return { verdict: m[1], out }
}

function applyPatch(probe) {
  const patchFile = join(PROBE_DIR, probe.patch)
  sh(`git -C ${JSON.stringify(KORU)} apply --check ${JSON.stringify(patchFile)}`)
  sh(`git -C ${JSON.stringify(KORU)} apply ${JSON.stringify(patchFile)}`)
}

function restore() {
  // Byte-identical: return to HEAD. Only safe when the tree was clean at start;
  // the battery asserts that invariant up front and refuses to run otherwise.
  sh(`git -C ${JSON.stringify(KORU)} checkout -- ${JSON.stringify('koru_std/interpreter.kz')}`)
}

// ---- invariants up front -------------------------------------------------
if (!existsSync(INTERP)) { console.error(`interpreter.kz not found: ${INTERP}`); process.exit(2) }
if (gitStatus('koru_std/interpreter.kz')) {
  console.error('refusing to run: koru_std/interpreter.kz is already modified. Stash or commit it first.')
  process.exit(2)
}

let anyFailed = false

function runProbe(probe) {
  try { applyPatch(probe) } catch (e) {
    console.error(`[probe ${probe.id}] patch would not apply cleanly: ${String(e.message).split('\n')[0]}`)
    restore()
    anyFailed = true
    return
  }
  let result
  try { result = runCloser() }
  catch (e) { console.error(`[probe ${probe.id}] closer infra error: ${String(e.message).split('\n')[0]}`); restore(); anyFailed = true; return }

  const ok = result.verdict === probe.expect
  if (!ok) anyFailed = true
  const verdict = result.verdict === 'FAIL' ? 'FAIL' : 'pass'
  console.log(`[probe ${probe.id}] ${ok ? 'ok ' : 'BROKEN'}  closer=${verdict}  expect=${probe.expect}  (${probe.why})`)

  restore()
  if (gitStatus('koru_std/interpreter.kz')) {
    console.error(`[probe ${probe.id}] restore failed — interpreter.kz still dirty.`)
    process.exit(2)
  }
}

console.log('== falsification battery, cross-language closer ==')
for (const probe of BATTERY) runProbe(probe)

// ---- final ground truth: a clean tree must still PASS -------------------
try {
  const final = runCloser()
  const ok = final.verdict === 'PASS'
  if (!ok) anyFailed = true
  console.log(`[restore] clean-tree closer=${final.verdict === 'FAIL' ? 'FAIL' : 'pass'} expect=pass ${ok ? 'ok' : 'BROKEN'}`)
} catch (e) {
  console.error(`[restore] closer infra error after battery: ${String(e.message).split('\n')[0]}`)
  anyFailed = true
}

console.log(anyFailed ? 'VERDICT: BATTERY FAILED (a contract was violated)' : 'VERDICT: BATTERY GREEN (cannot be flattered)')
process.exit(anyFailed ? 1 : 0)
