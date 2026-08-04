---
type: belief
id: frag-single-return-form-is-universal
provenance: introduced with the part3 std migration — fork ruled 2026-07-11 (no exemption), transformer decls land as -> SiteResult
ts: 2026-07-12
---

# The single-return form is universal — site-transformers included (belief)

A tag union exists for MULTIPLE dispatch branches. A single returned value
is the bare-return `-> T` form, and a lone `| value T` branch should fail
to compile (pinned 210_131). Lars ruled the fork 2026-07-11: there is NO
exemption for `[transform]`/`[keyword]`/`[norun]` site-transformer tors —
"one of those hard rules that should make sense everywhere," compiler core
included.

What sealed it: the lone `| transformed SiteResult` was never a real
branch. Generated handlers return SiteResult as a plain host return; the
Stage-A stub either unwraps a synthetic one-variant union (plain-proc
impls) or bypasses the decl entirely by machine convention
(`[transform]proc`). The branch declaration was read only as metadata — a
fiction the surface kept paying for.

Two impl conventions, one decl form:

- **Plain proc on a `[transform]` tor** (the print family, types, kernel,
  fmt, …): the generated Output IS the decl — bare-return decls make it
  SiteResult directly, and the proc returns it unwrapped. The stub returns
  the handler result verbatim.
- **`[transform]proc` machine convention** (store, field:new.on-stack):
  the generated struct hardcodes the transformed-union ABI regardless of
  the decl, so the decl's bare-return form is pure metadata there. A later
  consolidation could collapse this union too; it is an ABI choice, not a
  semantic one.

Surface note that the migration surfaced: a multi-line decl carries its
bare return on the closing-brace line (`} -> SiteResult`) — the parser
must treat the close-line tail as the decl's return suffix (020_037 pins
it; before the fix the tail was silently dropped, which is why wave 1's
multiline migrations sat arrow-less and undetected).

Open: field:new-instack's continuation-grafting migration and the
`[norun]` oddballs are case-by-case; the corpus burn-down (lone `| value
T` tests going red under the reject) is the ruled to-do list, not damage.

## The reject is uniform across ALL single-branch shapes, at the parser

Lars sharpened it 2026-07-15 ("identity branches with single payloads should
be handled the same as other continuation branches — a great find"): the
single-branch collapse is not a compound-only rule. Every lone `| ok …`
declaration collapses, and all three land as PARSE003 at parse time — the same
place compound single-branches were already enforced, which is why the parser
is the right home (an identity branch is no more special than a compound one):

- `| ok` (empty)        → "redundant — remove it to make a void event"
- `| ok i32` (identity) → "one-variant tag union — declare as bare return `-> i32`"
- `| ok { c: i32 }` (single-field brace), the advice is now **count-aware**:
  - SOLE branch → "one-variant tag union — declare as bare return `-> i32`"
  - one of ≥2 branches → "use identity `| ok i32`"

Surfaced by a stale unit test that *asserted* identity branches parse without
error (they never should have — the corpus had quietly exempted the identity
shape). Inverted to assert PARSE003.

## The ONE exemption: a wildcard `| c *` single branch — it is not a single shape (2026-07-16)

Building `cond` (flat multi-way dispatch — `cond(x) | c b when g -> v … | c _ -> d`,
`koru_std/control.kz`) surfaced the one shape "uniform reject" over-caught: a lone
`| c *`. A wildcard branch is NOT a one-variant union — the `*` is a declaration-time
signal that this single branch is FILLED BY N guarded arms at the use site (the same
`! each *` multifire idea, moved onto a terminal branch). `when`-guards turn one branch
name into N runtime paths — 355_007 already does exactly this for a `warning` branch
that happens to have siblings; `cond` is that pattern as the SOLE branch. So the
payload single-branch reject now exempts `is_wildcard`, mirroring the payloadless
sibling that already carried `!is_wildcard`. A FIXED lone `| ok i32` stays rejected —
it really is one shape; only the `*` (inherently multi-arm) form is exempt. The rule
conflated "one branch DECLARATION" with "one runtime VARIANT"; `when`-guards + `*`
break that equivalence. Pinned by 320_133 (cond green) and the parser exemption at the
210_131 site. cond is Lisp-`cond` (first-true predicate clauses), deliberately NOT
`switch` (value-case) nor `match` (structural patterns — reserved for a future
ADT/value-match construct; `match` is also already taken by std/parser).

The pit-of-success wrinkle is CLOSED (2026-07-16): the single-field-brace check
used to fire per-branch during parse, before the branch count was known, so a
SOLE `| ok { c: i32 }` was routed to `| ok i32` — itself illegal for a lone
branch, a two-hop path. It moved to post-parse (tor-decl validation), where
count is known: a sole braced-single-field falls through to the one-variant
bare-return check; a multi-branch one gets the identity advice. The two forms
are told apart post-parse by the field name — identity carries the `__type_ref`
sentinel; a braced single field keeps its real name. Pinned 210_063 (sole →
bare return) and 210_144 (multi → identity).

## The collapse reaches the PRODUCE/RESUME position too (2026-07-18)

The one-variant collapse is not a declaration-side-only rule: it governs every
`->` PRODUCE position. A single-field record RETURN (`-> { a: T }`) and a
single-field effect-arm RESUME (`! ask -> { a: T }`) both collapse to the scalar
`-> T` — the record earns its braces only at TWO OR MORE fields. `-> { a }` and
`-> a` carry identical information (bind `r` vs `r.a`); a one-field record is a
distinction without a difference, exactly like the one-variant branch payload and
the one-variant tag union above. Pinned 210_149 (bare-return) and 210_150 (effect
resume), rejected as PARSE003 at parse time.

**Repudiated**: 020_024 formerly pinned "a single-field record bare-return
`-> { total: i64 }` is legal; restricting the bare return to scalars would be the
arbitrary special case." That reading is wrong — *permitting* `-> { a }` is the
special case (two spellings for one value). 020_024 migrated to the legal
multi-field form. The multi-field record produce/resume is the real feature: it
now emits correctly (`struct { ... }` type, `.{ .a = ... }` value) — pinned by the
anonymous record resume 400_156.
