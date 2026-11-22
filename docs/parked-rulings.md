# Parked rulings — tor input axes (custody / content / syntax kind)

Parked 2026-11-16 for Lars to rule on cold. Each call states the question,
the evidence (with the tree it was measured on), the stakes, and what
"correct by construction" means if the natural design is right.

Measured trees:

- `main` @ `de7a618af` (korulang/koru, this checkout)
- `origin/quantity-numbers` @ `2d2a1d7b5` (Cypoe/koru, worktree
  `.claude/worktrees/qty-widen` in koru-cypoe, branch `qty-stringstar`)
- The producing session's tree ("koru-race", carrying `std/grammar`,
  `unit-reg-*`, `ext-canon`, `source:` params) is **gone / not on this
  machine** — anything attributed to it below is marked unverified.

Context: three axes now exist on every tor input — custody marks
(`string` vs `string<io:allocated!>` vs `string<*>`), content marks
(`!exact` / `!sexpr` / `!ext` taint gates), and syntax kinds
(`Expression` / `Source` params = call-site text and `{ }` blocks).

---

## Call 1 — content-text inputs take `string<*>`; do NOT make it the default

**Question.** Ratify "content-text inputs are `string<*>` unless the
param is itself a gate" as the spelling rule — and separately, should
`string<*>` become the *default* for unmarked `string` params, with
unqualified `string` reserved for taint-gate declarations?

**Evidence.**

- The need is real and reproduced: on quantity-numbers,
  `alg-add { a: string, b: string } -> string<std/io:allocated!>` —
  chaining `alg-add(alg-add(...))` refused `KORU030`:
  *"argument 'r1' is qualified as 'string<std.io:allocated!>' but
  parameter 'a' accepts only unqualified 'string' — declare '<*>' to
  accept any qualification."* The diagnostic itself teaches the fix.
- Re-applied and verified this session: commit `99af29246` on
  `qty-stringstar` — 37 signature lines / 56 params across 9 files
  (sym.alg, sym.rel, sym.certreg, sym.certgen, sym.supgen, quantity,
  num, num.nt, smt). Probe deep-check green; `615_057_sym_alg` PASS.
  `?string<*>` spells on this tree (split-expr unc/cov).
- Bare `string` already means "plain text, no outstanding obligation" —
  that is *why* `allocated!` outputs were refused. The mark carries
  information today.
- Gates are marked by content marks (`!sexpr`, `!exact`, `!external`,
  `!allocated`), not by custody spelling — the two axes are orthogonal
  by design.

**Stakes.** Ratifying the rule costs nothing — it is already the
enforcer's own teaching. Making `string<*>` the default inverts the
meaning of every existing unqualified `string` signature in the
stdlib (fs/http/fleet/node/compiler carry dozens) *silently* — no
diagnostic fires, the contract just changes meaning. It would also
collide with the gates: a gate param needs unqualified `string` plus
its content mark to mean "the boundary decides," and a custody-default
flip would force a second spelling for that.

**Correct by construction.** If the natural design is right, every
content-text param *visibly* carries whether it admits produced text —
`string<*>` is an explicit opt-in a reader can audit at the signature,
and a bare `string` param is a promise that only plain text enters.
Flipping the default would make the mark stop carrying information:
unmarked would silently mean "any custody," and the interesting case
(the gate) would need the mark instead. The information lives in the
explicit mark, not in the absence of one.

**Ruling requested:** ratify the rule as stated; reject the default
flip. Scope note: the wider pre-existing stdlib sweep is a separate
mechanical pass — this branch's surface is done.

---

## Call 2 — Expression/Source params are call-site text only

**Question.** Confirm "produced text never enters Expression/Source
params — runtime goes ingest/parse" is the intended rule, and that no
spelling for qualified-Expression params is needed.

**Evidence.**

- `src/parser.zig:11965-11978` (main): trailing `<…>` is peeled as a
  phantom for every field kind *except* File/EmbedFile/Expression,
  "whose `<T>` tail is part of their own spelling, not obligation
  state." So `Expression<*>` cannot spell "any custody" — there is no
  qualified-Expression spelling to widen, and none is needed.
- The producing session measured `lit(expr: r)` with produced
  (`allocated!`) text failing typecheck (`Expression<allocated!>` vs
  unqualified `Expression`) — unverified here, but the parser comment
  confirms the mechanism: the refusal is structural, not a gap.
- The ingest/parse gates exist for exactly this crossing:
  `num:ingest`, `sym:ingest`, `quantity:ingest`, `parser:parse` all
  take unqualified `string` and return `*!external!`/`*!sexpr-external!`
  marked values — produced text enters syntax-adjacent processing
  through a named, ledgered gate.
- Expression/Source params are landed on main: `num:lit { expr:
  Expression }`, `sym:lit { expr: Expression }`, `quantity:lit {
  source: Source }`, `rel-law/rel-derive/rel-norm { source: Source }`.

**Stakes.** If a custody-qualified Expression spelling existed,
runtime-produced text could pose as call-site syntax — the boundary
between "what the programmer wrote" and "what the program computed"
dissolves, and the taint story (`!sexpr` etc.) loses its reason to
exist. The refusal is the design working.

**Correct by construction.** If the rule is right, syntax channels
admit only syntax: an Expression/Source argument is text the tor
demands at the call site, captured verbatim, comptime-checkable. Every
produced-text-into-syntax act crosses a *named* gate — visible in the
signature, dischargeable, auditable. There is exactly one way in, and
it has a name.

**Corollary (same rule, already applied):** `rel-seed`/`rel-law`
`name:` stays `Expression` — a runtime-computed generator name is a
sign the *theory* should be data (law text already is, via `source:`
and the registry string), not that the name param should widen. If
that use case ever appears, the answer is a parse/ingest tor, not
`name: string<*>`.

**Ruling requested:** confirm the rule; document it in the spec next
to the phantom grammar (today the only hint is the parser comment).

---

## Call 3 — band 2b value-laws: inline law-kind marker, not a block keyword

**Question.** How does a value-law (declared equality the normalizer
applies, not a jet/shift law) declare itself in the `rel:v1` registry
block so it composes with the existing grammar without a second parse
lane?

**Evidence.**

- The registry is one string: `rel:v1;name=<lawtext>;...` —
  `relParse` (sym.rel.kz) walks `;name=<text>` entries and runs
  `parseTreeG` on each law text as a sexpr; `relEmit` serializes the
  same shape back. One parse lane, one serializer, round-trips.
- A value-law is the same *kind* of data as a jet law — a canonical
  sexpr — whose root denotes an equality rather than a derivative.
  The descent parser (`parseTreeG`) is where law syntax lives; a new
  head form (`eq(lhs,rhs)`) or an `==` token is a grammar row inside
  that parser, not a new lane.
- A new block keyword (or a `;eq:name=...` entry prefix) would fork
  the entry grammar: `relParse` would dispatch on entry shape, `relEmit`
  would need a second serializer arm, and the two lanes could drift.

**Stakes.** Low either way today — the registry is young. But the
spelling choice sets the precedent for every future law kind; a second
parse lane now is a permanent fork.

**Correct by construction.** If inline is right, the registry stays
one string in one grammar: `relParse`'s entry walk never learns about
law kinds, the normalizer pattern-matches the law root's form, and
adding a law kind is a row in the sexpr grammar — not a lane in the
registry. The kind lives in the *text*, where the grammar already is.

**Caveat:** the band-2b spec itself was not re-verified — if
value-laws turn out to be global (not per-generator), the entry-name
slot needs a reserved-marker convention; still inline, still one lane.

**Ruling requested:** spell value-laws inline in the law slot (headed
equality form in the sexpr grammar), no new block keyword.

---

## Also ruled in the same sitting (for completeness)

- **Auto-discharge policy:** explicit frees stay the corpus style;
  auto-insert (`src/auto_discharge_inserter.zig` — fires only on
  exactly one candidate or a `[!]`-marked preferred discharge, refuses
  ambiguity) is the safety net, not the idiom. Explicit frees pin
  obligations and are the only mid-pipeline release.
- **`std/grammar` port:** exists only on the lost koru-race tree —
  unverified here. If it resurfaces, landing it obliges concordance
  rows (docs/concordance-matrix.md lives on the `ccomp` branch only;
  `arm` is already doubly-minted) and a naming ruling: "Futamura" is
  parked as a specializer in AMBITIONS.md A1 but used as "data +
  shared walker" in grammar.kz — same word, two meanings.
