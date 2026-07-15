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

Status: the PARSER surface is excised (2026-07-15). Both spellings now fail
loudly at parse with PARSE003 "…the deferred/deref mechanism is retired.
Declare the call site with a required effect-branch instead" — a deferred decl
(`| &<branch>`) at both the event-decl and flow-continuation branch sites, and
a deref continuation (`| *<binding>`) at both continuation-parse sites. Pinned
210_145 (deferred) and 210_146 (deref). The old form no longer parses into dead
AST; it hits the wall at the language boundary.

What REMAINS dead-but-present (the deeper excision, still a follow-up): the
`deref` AST Node variant and the `is_deferred` Branch flag still thread ~10
passes (ast, flow_checker's transform-mode gating, serializer, printer — the
printer already marks both spellings "not grounded"). The parser now never
constructs a `deref` node nor sets `is_deferred` true (both are hardcoded false
locals), so those are unreachable code and the single-branch `!is_deferred`
exemption is a permanently-true no-op. Removing the Node variant + flag across
the passes is a Node-variant removal on the scale of a five-layer AST threading
— worth doing, but not blocking. The pipeline test that pinned the parsed shape
(`end-to-end with deferred events`) is deleted; a dead feature keeps no coverage.
