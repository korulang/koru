---
type: belief
id: frag-a-transform-on-a-runtime-event-is-a-check-lane
provenance: std/quantity static dim-check (615_075, KORU189) — a `~[transform]proc` on the ordinary `add`/`sub` events, measured across ~6 emission failures
ts: 2026-11-14
tags: [transforms, comptime, quantity, machine-params, site-view]
---

# A `~[transform]proc` on an ordinary runtime event is a legal compile-time check lane (belief)

Every prior `[transform]proc` paired with a `[comptime|transform]` event.
A runtime event can carry one too — the event keeps its ordinary user surface
and runtime handler; the proc attaches a compile-time guard that inspects each
call site and either declines (`.transformed = .{}`, the runtime call proceeds)
or refuses via `ast.refuse(reporter, .KORU…, …)`. Quantity's static
dim-check is the first instance: `add`/`sub` trace chain-bound operand names to
`std/quantity:lit` producers and refuse a statically-decided mismatch while the
`| dim-mismatch` arm stays the law for everything opaque.

Three measured mechanics made it work:

- **Machine params opt in via `?`-optionality.** `reporter: ?*ErrorReporter`
  on the event decl is name-detected for the transform ABI (the handler's
  Input carries a real `*ErrorReporter`) while `?` exempts it from `|>`
  thread-filling — optional params are never fill candidates, so
  `|> add(a, b)` does not try to thread into it. A non-optional machine param
  on a runtime event is an unfillable user param and breaks every call site.
- **The event has TWO emitted views; neither may leak.** In the comptime emit
  the event lowers to its transform-ABI struct (`invocation/item/program/
  allocator/reporter`); in the runtime emit it must lower the ordinary event
  struct — `emit_mode` gates the override. The runtime `Input` substitutes a
  dead `reporter: ?*anyopaque = null` slot (the generated handler still
  destructures it) and the signature-home scan must skip the field, else
  `std.compiler`'s `ErrorReporter` home welds the whole compiler module —
  `log`, `errors`, test-gen bodies — into the emitted program.
- **A nested dispatch hands a re-rooted view, not the program.** The handler's
  `item.flow.body` IS the holding continuation; ancestors live in the real
  program: `flow.site_of` is the real continuation pointer and
  `emitter_helpers.findFlowHoldingCont(program.items, site)` recovers the
  real flow. Walking `flow.body` for chain bindings sees only the site —
  the single most likely mistake writing a scope-sensitive transform.

## Open

`equiv` was deliberately left runtime-only: `equiv(m, s)` is a total question
with a legitimate "no" answer, not a nonsense operation — refusing it would
reject valid programs. Whether that line (refuse nonsense ops, keep total
queries runtime) is the right policy is unmeasured.
