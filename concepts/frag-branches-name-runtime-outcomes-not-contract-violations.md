---
type: belief
id: frag-branches-name-runtime-outcomes-not-contract-violations
provenance: std/rand review — `between`/`below` shipped with an `| empty` branch modeled on `parse-int`'s `| err`, forcing every call site to write a dead arm for a case that is a bug, not data
ts: 2026-10-29
---

# Branches name runtime outcomes; contract violations are panics

`parse-int`'s `| err` and `readln`'s `| failed` exist because bad input
and I/O failure are legitimate runtime events — the user types garbage,
the file does not exist, the caller must decide what happens next. An
inverted range `between(7, 1)` is none of that: the bounds are the
caller's own contract, and honoring it with a branch makes the misuse
indistinguishable from data — and taxes every correct call site with a
`| empty |> _` arm for a case that cannot legitimately occur.

The class check: **could this outcome happen to a correct program?**
`store`'s `| empty` passes (a store can be empty at runtime); `rand`'s
did not (a correct caller never inverts its own range). Contract
violations deserve the honest loud failure — the Zig safety check
inside `intRangeAtMost` panics with the call site in the trace — and
the bare `-> i64` keeps the call sites clean. If a caller's bounds are
runtime-computed, guarding `hi > lo` is *their* obligation to spell,
not a branch we impose.
