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
extending to `/` path atoms. Open rulings, deliberately unpinned: bare
identifier on a comparison's RHS (symbol vs resolution atom); brackets vs
parens for entry parameterization (brackets rhyme with the variant/selection
language, parens with the call form); whether the deliberately-feral
annotation forms survive the expression-list grammar (lean: no, loudly);
whether [[frag-arguments-are-atoms]]'s calls-are-not-expressions wall treats
annotation entries as a quoting surface (entries are comptime data handed to
consumers, so call-shaped entries are data, not execution — unruled).

Pairs with [[frag-expression-source-are-strings-not-comptime]] (annotation
entries are another captured-representation surface whose meaning belongs to
the consumer) and the mlir selection-language thread (same expression
organs, different vocabulary on top).
