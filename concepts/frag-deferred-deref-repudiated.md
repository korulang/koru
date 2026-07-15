---
type: belief
id: frag-deferred-deref-repudiated
provenance: repudiated 2026-07-15 (Lars) — deferred/deref killed; first-class events do not travel as runtime pointers
ts: 2026-07-15
---

# Deferred events / deref (`&branch` / `*binding`) are REPUDIATED (belief)

An early attempt to make events **first-class** — a `| &selected T` *deferred*
branch decl paired with a `| *s` *deref* continuation that "unpacks" a deferred
value later in the flow. The mechanism was a **runtime pointer**: the event (or
its unresolved branch) got passed around and dereferenced. Lars killed it
2026-07-15: over-ambitious, or just bad design, or built before we understood
the problem — but decisively wrong as the mechanism for events-as-first-class,
"because it uses pointers and I don't want it."

Why it's wrong, and what replaces it: the real need deferred/deref reached for
is *"I need something to call here, supplied from outside."* Two more elegant
mechanisms serve that now, both **monomorphized, no pointers**:

- **Required effect-branches** already say exactly "I need something to call
  here" and monomorphize the supplied behavior inline — perfectly, instead of
  threading a pointer. This is the live answer today.
- **A comptime pass-the-event-by-name construct** (parked idea, 2026-07-15, NOT
  built): pass an event *by name* at compile time and have it expand inline and
  monomorphized at each use site — first-class-event ergonomics with zero
  runtime indirection. Lars: "that actually solves this whole problem." Do not
  build on a hunch; it needs its own design walk. The bar it must clear: no
  pointer ever escapes; every use site monomorphizes.

The hard constraint underneath all of it: **you cannot pass a koru event around
as a runtime pointer.** Any "first-class event" surface must resolve to inline,
monomorphized expansion — the same instinct as the language's other collapses
toward concrete, one-variant forms ([[frag-single-return-form-is-universal]]).

Status: the surface is dead but not yet excised. The `deref` AST Node variant
and the `is_deferred` Branch flag still thread ~10 passes (ast, parser,
flow_checker's transform-mode gating, serializer, printer — the printer already
marks both spellings "not grounded"). Ripping them out (and making `&`/`*`
fail loudly at parse) is a Node-variant removal on the scale of a five-layer AST
threading — a real follow-up endeavor, not a one-liner. The pipeline test that
pinned the parsed shape (`end-to-end with deferred events`) is deleted; a dead
feature keeps no coverage.
