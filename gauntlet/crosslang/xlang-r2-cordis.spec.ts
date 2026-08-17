// Cross-language gauntlet, rung R2 fixture — CORDIS SIDE (machine-readable).
//
// Scenario: recovery exactness (the paper's soundness invariant, phi(gamma) =
// gamma_0, Theorem 61). The accumulator applies EACH inverse EXACTLY ONCE: a
// resource explicitly released mid-session must NOT be released again when
// its enclosing scope hangs up. Double-release is a doubled inverse — the one
// failure the accumulator exists to prevent. Koru twin: 440_013 (open a.txt,
// open b.txt, close a.txt explicitly, hang up — only b may be released).
//
// Cordis shape: a parent fiber owns TWO provider children, `storeA` and
// `storeB`. We explicitly dispose the A child mid-session (its disposer
// withdraws A NOW), then dispose the parent (hang-up; B's disposer runs).
// The invariant: each binding withdraws EXACTLY ONCE in the whole trace — A
// not again at parent teardown, B exactly once.
//
// NOTE on a measured artifact: `service|set|storeX` may re-emit during
// notify (the R1 closer documented the same). The invariant is on the
// WITHDRAW side — the irreversible half — which must fire exactly once.
//
// Emitted contract: every line starts with `TRACE `, final line
// `TRACE_JSON <json-array>` carrying the full ordered event list.
//
// Run: cd /Users/larsde/src/cordis-ref
//      bunx vitest run packages/core/tests/xlang-r2-cordis.spec.ts

import { Context } from '../src'
import { describe, it, expect } from 'vitest'

type FiberHandle = {
  dispose: () => Promise<void>
}

export function makeExactnessTrace() {
  const root = new Context()
  const events: string[] = []

  for (const ev of ['internal/plugin', 'internal/service'] as const) {
    root.on(ev, ((...args: unknown[]) => {
      if (ev === 'internal/plugin') {
        const self = args[0]
        const uid = self && typeof self === 'object' && 'uid' in self ? String(self.uid) : '?'
        events.push(`plugin|install|${uid}`)
      } else {
        const name = typeof args[0] === 'string' ? args[0] : '?'
        const value = args[1]
        events.push(value == null ? `service|withdraw|${name}` : `service|set|${name}`)
      }
    }) as (ev: string, ...args: unknown[]) => void)
  }

  function provider(name: string) {
    return async function installProvider(ctx: Context) {
      ctx.provide(name, { data: 1 })
    }
  }

  return {
    async run() {
      const parentFiber = await root.plugin(async (ctx) => {
        const aFiber = (await ctx.plugin(provider('storeA'))) as unknown as FiberHandle
        await ctx.plugin(provider('storeB'))
        // Mid-session: explicitly dispose the A child. Its disposer runs NOW.
        await aFiber.dispose()
      })
      // Hang-up: dispose the parent — B's disposer runs; A must NOT re-run.
      await parentFiber.dispose()
      return events
    },
  }
}

describe('xlang R2 — cordis side', () => {
  it('each binding withdraws EXACTLY ONCE (recovery exactness, Thm 61)', async () => {
    const { run } = makeExactnessTrace()
    const events = await run()
    const aSets = events.filter(t => t === 'service|set|storeA').length
    const bSets = events.filter(t => t === 'service|set|storeB').length
    const aWith = events.filter(t => t === 'service|withdraw|storeA').length
    const bWith = events.filter(t => t === 'service|withdraw|storeB').length
    console.log('XLANG_CORDIS ' + JSON.stringify(events))
    // Both bindings were installed...
    expect(aSets).toBeGreaterThanOrEqual(1)
    expect(bSets).toBeGreaterThanOrEqual(1)
    // ...and each withdrew EXACTLY ONCE. The explicit A-dispose plus parent
    // teardown together apply A's inverse a single time; B's a single time.
    expect(aWith).toBe(1)
    expect(bWith).toBe(1)
  })
})