---
type: belief
id: frag-annotation-entries-are-expressions
provenance: walked with Lars 2026-07-10 (formalization arc); frontmatter added 2026-07-20 on the consumer-relative-rejection evolve
ts: 2026-07-20
---

# Annotation entries are expressions; consumers own policy (belief)

An annotation block is a **list of entries** — pipe-separated inline,
bullet-separated vertical, prose lines being human rationale addressed to the
reader, not the machine. The pipe/bullet is a *list delimiter and
semantically silent*: combination logic across entries has NO language-level
answer, by design. Each **entry** is an expression in the one shared
expression grammar (the when-clause grammar) — a bare identifier is the
degenerate case, a call is an entry, and comparisons/logic compose *inside*
one entry, where the author owns the semantics. Direction walked with Lars
2026-07-10; the frontier is pinned at 310_104 and 310_105.

The layering, matching the open-metadata ruling (frontend validates nothing,
passes define meaning):

- **Grammar** (language): entries parse once into expression AST. The
  language guarantees *shape*, never meaning.
- **Library** (stdlib): one evaluator — `comptime_eval`, with its loud-failure
  contract — plus **reader-side provenance resolution**: bare atoms resolve
  through a documented provider chain (compiler flags → build config →
  process env → absent-is-false) and the result carries its *source*. The
  author writes the terse intent-shaped thing; the resolution answers "where
  did this value come from this build," and the compiler reports it loudly
  when a resolution gates code in or out. Scoped lookups (`cflag(x)`,
  `env(x)`) are the narrowing exception, not the grammar. Graph resolution
  (dependency entries → topo order / cycle diagnostics) is the same kind of
  library call, reusable from comptime.
- **Conventions** (consumers): each pass decides which entries it honors and
  applies its own policy over provenance. The evaluator is opt-in
  convenience, never mandate — that voluntary convergence, not language
  mandate, is what retires the hand-rolled per-consumer scanners.

Why this is worth believing: writer-side provenance (enumerating sources in
every file) is clunky and brittle; reader-side provenance keeps the surface
terse and moves the trace to where it can actually be answered — the build.
And silent gating is the failure class the whole design exists to kill: an
entry that cannot be evaluated, or that drops code, must say so.

Grammar rulings settled on the walk: kebab-greedy lexing (unspaced `-` joins
identifiers; subtraction requires spaces), with the same unspaced rule
extending to `/` path atoms.

Two rulings settled 2026-07-20 (walked with Lars on the `koruc explain`
design night):

- **Rejection is consumer-relative; there is no global rejector.** The
  earlier open question — "do the deliberately-feral annotation forms
  survive the expression-list grammar (lean: no, loudly)?" — dissolved
  rather than resolved: it presumed a language-level rejection pass that
  the layering forbids. The language stores entries opaquely (the 310_010
  pin is unmoved); a consumer that *evaluates* an entry and cannot errs
  loudly *as itself*; a consumer that ignores an entry ignores it freely.
  The import gate is the first evaluating consumer and the one that IS the
  core language — it runs at parse time and decides AST membership — so its
  entries MUST evaluate (the KORU150 wall). The same annotation that is
  legally inert on an event is an error on an import; the asymmetry is
  correct because an inert entry on an import is silent gating, the failure
  class this whole design exists to kill.
- **A bare identifier on a comparison's RHS is a SYMBOL — the word itself,
  never a chain lookup.** `build == release` asks "is build the word
  release"; resolving the RHS through the provider chain under
  absent-is-false would make the comparison always-false, which nobody
  means. Position carries the role: entry-root and truthiness positions
  resolve; comparison-RHS is a value position. Rhymes with `~[build(macos)]`
  variant keys, where the parenthesized word is already a value.

**Scope limit discovered 2026-07-27, not yet resolved.** The claim above that
the import gate "MUST evaluate" its entries assumed the gate evaluates the same
way everywhere. It does not — only the ENTRY file's gates see the build's
provider chain, and a gate one import deeper resolves everything to absent.
`310_113` is the red pin carrying the contradiction, and `310_104` is its green
entry-file twin; the two differ only in which file holds the annotation. So the
belief stands as the RULING and fails as a description of the implementation.
Which way it resolves — thread the flags down, or declare nested gates
deliberately flag-blind — is unruled, and the pin holds the question open
rather than a doc sentence.

Still open, deliberately unpinned: brackets vs parens for entry
parameterization (brackets rhyme with the variant/selection language, parens
with the call form); whether [[frag-arguments-are-atoms]]'s
calls-are-not-expressions wall treats annotation entries as a quoting
surface (entries are comptime data handed to consumers, so call-shaped
entries are data, not execution — unruled).

Pairs with [[frag-expression-source-are-strings-not-comptime]] (annotation
entries are another captured-representation surface whose meaning belongs to
the consumer) and the mlir selection-language thread (same expression
organs, different vocabulary on top).
