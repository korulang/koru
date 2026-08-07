---
type: belief
id: frag-struct-literal-pun-law
provenance: found this session chasing a to-do app's `insert { label: label }`; captured's bare form proven POSITIONAL (320_136); fix implemented by Grok 4.5, reviewed + landed 2026-07-23 (pins 320_136, 690_071, 690_072)
ts: 2026-07-23
---

# The struct_literal-block family obeys Koru's pun law — nothing positional, punning mandatory (belief)

Koru has two invariants: **nothing is positional** (fields addressed by name),
and **punning is mandatory** (`{ label }`, not the redundant `{ label: label }`;
a genuine rename `{ x: other }` is fine). Its destructure machinery enforces this
everywhere it runs (`! sweep { label }`, query projections, branch payloads).

But a whole family of constructs takes its `{ … }` block as a `source: Source`
(opaque text) parsed by a SEPARATE hand-rolled projector,
`struct_literal.parseFields` — NOT the destructure machinery. That family
(`captured`, `std/store:insert`, `std/store:stored`, store field-defaults, …) was
an ISLAND that never implemented the law, and each construct improvised a
different, wrong interpretation of a bare entry:

- **`captured { a, b }` was POSITIONAL** — a bare entry mapped to the cell's
  declared field BY INDEX (`cells[i].name`). Proven: the SAME two expressions,
  reordered, silently landed in DIFFERENT fields, no error (320_136). LATENT — the
  whole corpus only used the named form, so the positional footgun never fired,
  but it was live in the compiler. Positional, in the language that forbids it.
- **Store writes went the OTHER wrong way**: `insert { label }` (the pun) errored
  "missing column", while `insert { label: label }` (the redundancy) compiled
  silently — forcing exactly the shape destructures forbid, rejecting the pun they
  mandate.

## The law, now enforced in the shared parser (not per-construct)

The fix lives at the root — `struct_literal` itself — so the island dissolves and
every consumer inherits one rule (`punnableName`, kept in lockstep with
`lexer.punnableName`):

- **Bare punnable name/path** (`label`, `acc.sum`) → PUN by last segment
  (field = `label` / `sum`; value = the name/path).
- **Bare expression** (`a.x + 1`, anything with operators) → REJECT: *"positional
  assignment is never allowed — name the target (`x: expr`)"*. An expression can't
  pun (no name to match), so a positional fallback is the only alternative — and
  that alternative is the sin.
- **Redundant explicit label** (`x: x`, `sum: acc.sum` where the field name equals
  the value's last segment) → REJECT: *"punning is mandatory — drop the redundant
  label and write the bare pun"*.
- **Carve-out**: a SINGLETON bare non-punnable entry under
  `allow_singleton_expression` — capture's existing-value SEED
  (`capture { entity }` / `capture { expr }`). Write blocks
  (`captured`/`insert`/`stored`) leave it off, so a lone bare expression in a
  WRITE is rejected.

`captured`'s `cells[i].name` positional mapping was DELETED — there is no
positional path left anywhere.

## Why it matters / what it revealed

The bespoke island also meant store-write VALUES were raw text
(`insert { v: 2 + 2 }` passed `"2 + 2"` verbatim), so they likely bypassed Koru's
expression wall (KORU104, "no call in an expression"). Whether routing through the
real machinery closes that too is an OPEN follow-up (a `insert { v: <a call> }`
probe). The deeper principle: a construct that re-parses raw text instead of
consuming Koru's real destructure/expression nodes is an island, and islands
drift off-law — the fix is always to consume the real machinery, not to patch the
island's private parser.

Board Broken:0: the mandatory-punning rule forced rewrites of every
`field: path.field` site in the corpus (670_045, 810_091/092/131/132 — AoC, exact
outputs unchanged, so the rewrites are provably equivalent). 320_136 / 690_071 /
690_072 flipped RED→GREEN.

## A pun can also be destroyed UPSTREAM of the lowering (2026-08-08)

A third way to break the law, found in 210_025: the pun lowering itself was
correct, but a textual pass that runs BEFORE it — bare-return param
substitution (`substituteParamNamesInPlainValue`) — replaced the punned
identifier with the call-site value, so the lowering received `{ 10, 20 }` and
minted `.{ .10 = 10 }`: the VALUE promoted to field name. In a pun the
identifier is the name AND the value; any rewrite that touches one must
preserve the other. The substitution now expands the pun in place
(`{ x, y }` → `{ x: 10, y: 20 }`) when its match sits in punned field
position. Same law, new obligation: every pass that rewrites text upstream of
the pun lowering owes the punned name its survival.
