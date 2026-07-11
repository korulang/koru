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
exemption for `[transform]`/`[keyword]`/`[norun]` site-transformer events —
"one of those hard rules that should make sense everywhere," compiler core
included.

What sealed it: the lone `| transformed SiteResult` was never a real
branch. Generated handlers return SiteResult as a plain host return; the
Stage-A stub either unwraps a synthetic one-variant union (plain-proc
impls) or bypasses the decl entirely by machine convention
(`[transform]proc`). The branch declaration was read only as metadata — a
fiction the surface kept paying for.

Two impl conventions, one decl form:

- **Plain proc on a `[transform]` event** (the print family, types, kernel,
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
