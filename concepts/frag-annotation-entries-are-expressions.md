# Annotation entries are expressions; consumers own policy (belief)

An annotation block (`~[...]`, inline or vertical) is a **list of entries**:
pipe-separated inline, bullet-separated vertical, prose lines being human
rationale the parser deliberately discards (parser.zig:1142). The pipe/bullet
is a *list delimiter and semantically silent* — combination logic across
entries has NO language-level answer, by design. Each **entry** is an
expression in the shared expression grammar (the when-clause grammar): a bare
identifier is the degenerate case (today's `comptime`), a call is an entry
(`depends_on("a")`), and comparisons/logic compose *inside* one entry
(`build == "release"`, `profile and !test`) where the author owns the
semantics. Direction walked with Lars 2026-07-10; grammar formalization is
the ruled intent, surface details still in flight.

The layering, matching the open-metadata ruling (frontend validates nothing,
passes define meaning):

- **Grammar** (language): entries parse once into expression AST. The
  language guarantees *shape*, never meaning.
- **Library** (stdlib): one evaluator (`comptime_eval`, loud-failure
  contract) plus **reader-side provenance resolution** — bare atoms resolve
  through a documented provider chain (compiler flags → build:config →
  process env → absent-is-false) and the result carries its *source*, so
  `[profile]import` stays terse while `resolve("profile")` answers where the
  value came from. Scoped lookups (`cflag(x)`, `env(x)`) are the narrowing
  exception, not the grammar. Graph resolution (depends-on → topo order /
  cycle diagnostics) is the same kind of library call.
- **Conventions** (consumers): each pass decides which entries it honors and
  applies its own policy over provenance. The evaluator is opt-in
  convenience, never mandate.

**Why this is a belief change (probed 2026-07-10, all SHOWN).** The prior
working assumption was that the existing annotation machinery composed. It
does not — the "language" is five disconnected string-matchers: the
frontend's opaque-string store; `annotation_parser.zig`'s split/trim queries
re-parsed at ~30 call sites; the import gate's exact string-equality against
flag strings (parser.zig:951); `build.kz:matchesFlags`'s hardcoded implicit-
OR (copy-pasted a third time in deps.kz:265); and the `mlir[gpu]` variant
scanner. Concrete contradictions: multiline annotations (green, 310_008) and
conditional imports (green, 310_027/029) were assumed to compose — the
composition never existed (`]import` is PARSE003; annotation above `~import`
silently detaches to module level). `[build(release)]import` was assumed to
gate on `--build=release` — it silently drops the import in ALL
configurations, because the gate matches `build=release` (flag spelling) and
only a *different* consumer understands `build(...)`. Pinned as TODO-red
310_104 (multiline conditional import) and 310_105 (expression entry, with
the load-bearing-import-via-tap mechanism from 310_001).

Grammar decisions settled on the walk: whitespace around `|` is already
normalized (both layers trim); kebab identifiers require kebab-greedy lexing
(unspaced `-` joins names, subtraction needs spaces — zero corpus casualties
in when-guards) and the same unspaced rule extends to `/` path atoms. Open
edges: bare-identifier RHS in comparisons (`build == release` — symbol or
resolution atom?); brackets-vs-parens for entry parameterization
(`depends-on[app/a]` rhymes with the `mlir[gpu]` variant language, `(...)`
is the corpus call form); whether the feral 310_010 forms
(`profile "with spaces" 1000Hz`, `inline@500`) survive the expression-list
grammar (lean: no, loudly); and whether [[frag-arguments-are-atoms]]'s
calls-are-not-expressions wall treats annotation entries as a quoting
surface (entries are comptime data handed to consumers, so call-shaped
entries are data, not execution — but that exemption is not yet ruled).

Pairs with [[frag-expression-source-are-strings-not-comptime]] (annotation
entries are another captured-representation surface whose meaning belongs to
the consumer) and the mlir selection-language thread (same expression organs,
different vocabulary on top).
