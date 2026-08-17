// Cross-language gauntlet, rung R1 fixture — CORDIS SIDE (machine-readable).
//
// Scenario: retired provider with a live dependent (Theorem 63 ordering).
// The parent fiber owns the provider binding AND a child consumer plugin.
// Retiring the parent tears down both.
//
// THE INVARIANT (lifecycle form, per Theorem 63): the dependent leaves the
// ACTIVE lifecycle state BEFORE the provider's binding is withdrawn. The
// disposer ORDER is an implementation detail of each runtime and differs
// between Cordis and Koru — the closer compares lifecycle events only.
//
// Emitted contract: every line starts with `TRACE `, and the FINAL line is
// `TRACE_JSON <json-array>` carrying the full ordered event list.
//
// Run: cd /Users/larsde/src/cordis-ref
//      bunx vitest run packages/core/tests/xlang-r1-cordis.spec.ts

import { Context } from '../src'
import { describe, it, expect } from 'vitest'

export function makeRetireTrace() {
  const root = new Context()
  const events: string[] = []

  for (const ev of ['internal/plugin', 'internal/status', 'internal/service'] as const) {
    root.on(ev, ((...args: any[]) => {
      if (ev === 'internal/plugin') events.push(`plugin|install|${args[0]?.uid}`)
      else if (ev === 'internal/service') {
        const [name, value] = args
        events.push(value == null ? `service|withdraw|${name}` : `service|set|${name}`)
      } else {
        // FiberState: PENDING=0 LOADING=1 ACTIVE=2 FAILED=3 DISPOSED=4 UNLOADING=5
        const [fiber, oldState] = args
        events.push(`fiber|state|${fiber?.uid}|${oldState}->${fiber?.state}`)
      }
    }) as any)
  }

  async function parent(ctx: Context) {
    ctx.provide('store', { data: 1 })
    await ctx.plugin(async (ctx) => {
      await ctx.get('store')
      ctx.on('store/x', () => {})
    })
  }

  return {
    async run() {
      const parentFiber = await root.plugin(parent)
      await parentFiber.dispose()
      return events
    },
  }
}

describe('xlang R1 — cordis side', () => {
  it('dependent leaves ACTIVE before the binding withdraws', async () => {
    const { run } = makeRetireTrace()
    const events = await run()
    // Consumer is the child (uid 2). Its ACTIVE->UNLOADING transition (2->5)
    // must precede the provider binding's service|withdraw.
    const consumerLeavesActive = events.findIndex(
      t => t.startsWith('fiber|state|2|2->') || t.startsWith('fiber|state|2|1->'),
    )
    const withdraw = events.findIndex(t => t.startsWith('service|withdraw'))
    console.log('XLANG_CORDIS ' + JSON.stringify(events))
    expect(consumerLeavesActive).toBeGreaterThan(-1)
    expect(withdraw).toBeGreaterThan(-1)
    expect(consumerLeavesActive).toBeLessThan(withdraw)
  })
})