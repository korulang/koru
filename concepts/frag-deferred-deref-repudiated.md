---
type: belief
id: frag-deferred-deref-repudiated
provenance: repudiated 2026-07-15 (Lars) — deferred/deref killed; first-class tors do not travel as runtime pointers
ts: 2026-07-15
---

# Deferred tors / deref (`&branch` / `*binding`) are REPUDIATED (belief)

An early attempt to make tors **first-class** — a `| &selected T` *deferred*
branch decl paired with a `| *s` *deref* continuation that "unpacks" a deferred
value later in the flow. The mechanism was a **runtime pointer**: the tor (or
its unresolved branch) got passed around and dereferenced. Lars killed it
2026-07-15: over-ambitious, or just bad design, or built before we understood
the problem — but decisively wrong as the mechanism for tors-as-first-class,
"because it uses pointers and I don't want it."

Why it's wrong, and what replaces it: the real need deferred/deref reached for
is *"I need something to call here, supplied from outside."* Two more elegant
mechanisms serve that now, both **monomorphized, no pointers**:

- **Required effect-branches** already say exactly "I need something to call
  here" and monomorphize the supplied behavior inline — perfectly, instead of
  threading a pointer. This is the live answer today.
- **A comptime pass-the-tor-by-name construct** (parked idea, 2026-07-15, NOT
  built): pass a tor *by name* at compile time and have it expand inline and
  monomorphized at each use site — first-class-tor ergonomics with zero
  runtime indirection. Lars: "that actually solves this whole problem." Do not
  build on a hunch; it needs its own design walk. The bar it must clear: no
  pointer ever escapes; every use site monomorphizes.

The hard constraint underneath all of it: **you cannot pass a koru tor around
as a runtime pointer.** Any "first-class event" surface must resolve to inline,
monomorphized expansion — the same instinct as the language's other collapses
toward concrete, one-variant forms ([[frag-single-return-form-is-universal]]).

Status: the PARSER surface is excised (2026-07-15). Both spellings now fail
loudly at parse with PARSE003 "…the deferred/deref mechanism is retired.
Declare the call site with a required effect-branch instead" — a deferred decl
(`| &<branch>`) at both the tor-decl and flow-continuation branch sites, and
a deref continuation (`| *<binding>`) at both continuation-parse sites. Pinned
210_145 (deferred) and 210_146 (deref). The old form no longer parses into dead
AST; it hits the wall at the language boundary.

The AST gutting is DONE too (2026-07-15): the `deref` Node variant and the
`is_deferred` Branch flag are removed from `ast.zig` and every pass that walked
them — ast_functional/ast_transform (clone), ast_mangle, ast_serializer,
ast_printer, canonicalize_names, dead_strip, flow_checker, emitter_helpers — plus
the now-dead `parseDerefContinuation`/`parseDerefContinuationBase` functions and
the single-branch `!is_deferred` exemption (a lone `| &` was the only reason it
existed). No `deref`/`is_deferred` reference survives in `src/`. The concept is
gone from the AST entirely, so no pass can lie about the language still having it.
The pipeline test that pinned the parsed shape (`end-to-end with deferred
events`) is deleted; a dead feature keeps no coverage.
