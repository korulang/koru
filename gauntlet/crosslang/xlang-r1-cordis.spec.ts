// Cross-language gauntlet, rung R1 fixture — CORDIS SIDE.
//
// Scenario: retired provider with a live dependent (Theorem 63 ordering).
// A provider plugin installs service `store`; a consumer plugin injects it.
// Retiring the provider must run the consumer's teardown FIRST, then the
// provider's own, then withdraw the service. This file records the trace
// the closer expects; the same scenario in the Koru bridge must normalize
// to the same event vocabulary.
//
// Run:  cd /Users/larsde/src/cordis-ref
//       bunx vitest run packages/core/tests/xlang-r1-cordis.spec.ts
//
// Event vocabulary (the shared closer contract):
//   plugin|install|<uid>         fiber created
//   service|set|<name>           value provided
//   service|withdraw|<name>      binding removed
//   <role>|teardown              disposer ran (consumer before provider)

import { Context } from '../src'
import { describe, it, expect } from 'vitest'

export function makeRetireTrace() {
  const root = new Context()
  const trace: string[] = []

  // Registered exactly like the working probe: loop over names, spread args.
  for (const ev of ['internal/plugin', 'internal/status', 'internal/service'] as const) {
    root.on(ev, ((...args: any[]) => {
      if (ev === 'internal/plugin') {
        trace.push(`plugin|install|${args[0]?.uid}`)
      } else if (ev === 'internal/service') {
        const [name, value] = args
        trace.push(value === undefined || value === null
          ? `service|withdraw|${name}`
          : `service|set|${name}`)
      } else if (ev === 'internal/status') {
        const [fiber, oldState] = args
        trace.push(`fiber|state|${fiber?.uid}|${oldState}->${fiber?.state}`)
      }
    }) as any)
  }

  async function provider(ctx: Context) {
    ctx.provide('store', { data: 1 })
    return () => { trace.push('provider|teardown') }
  }
  async function consumer(ctx: Context) {
    await ctx.get('store')
    return () => { trace.push('consumer|teardown') }
  }

  return {
    async run() {
      const provFiber = await root.plugin(provider)
      await root.plugin(consumer)
      await provFiber.dispose()
      return trace
    },
  }
}

describe('xlang R1 — cordis side', () => {
  it('retires the dependent before the provider', async () => {
    const { run } = makeRetireTrace()
    const trace = await run()
    // Theorem 63: provider teardown after consumer teardown; service
    // withdraw strictly last.
    const consumerAt = trace.findIndex(t => t === 'consumer|teardown')
    const providerAt = trace.findIndex(t => t === 'provider|teardown')
    const withdrawAt = trace.findIndex(t => t.startsWith('service|withdraw'))
    expect(consumerAt).toBeGreaterThan(-1)
    expect(providerAt).toBeGreaterThan(-1)
    expect(withdrawAt).toBeGreaterThan(providerAt)
    expect(consumerAt).toBeLessThan(providerAt)
    console.log('XLANGTRACE')
    for (const t of trace) console.log('TRACE', t)
  })
})