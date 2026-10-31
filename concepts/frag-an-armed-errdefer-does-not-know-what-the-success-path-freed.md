---
type: belief
id: frag-an-armed-errdefer-does-not-know-what-the-success-path-freed
provenance: a deriv on a flat all-zero-factor mul leaked one allocation; the leak check caught it, and widening the audit found the same shape arming double-frees on every error path
ts: 2026-11-01
---

# An armed errdefer does not know what the success path freed (belief)

`errdefer` is a statement about the error path only. Two failure shapes fall
out of that single fact, and `std/sym` grew both.

**The empty-success leak.** `deriveNodeG`'s product rule built `terms` with
`initCapacity`, derived every factor, and on `terms.items.len == 0` returned
`decZero` — a normal return, so the armed `errdefer` never fired and the
backing buffer leaked. Every skipped factor is *expected* (a constant factor
derives to zero), so the leak path is the common one, not the corner. The
meter read count=1 for a whole family: `lit(s:"1e0+*x") -> bad` leaked the
partially-parsed `lhs` for the same reason at the parse layer — `errdefer`
coverage was simply absent there.

**The armed-after-transfer double-free.** `nodeFree(inner); return try
something()` leaves the `errdefer nodeFree(inner)` armed: if the trailing
`try` fails, the error path frees `inner` a second time. The `usize` counter
wraps on the double-decrement and reports the same nonzero as a leak — the
diagnostic cannot tell a leak from a double-free, only that the balance is
wrong. Every `try list2(...)`/`try nodeList(...)` fed by a `toOwnedSlice`
shared the shape: on failure the moved slice and its nodes had no owner left.

The ruling: **the moment ownership moves, disarm the guard that covered the
old owner.** The codebase already had the idiom — `coeff_live` in `norm`'s
mul branch — a boolean the errdefer checks (`errdefer if (x_live) free(x)`),
cleared at the transfer point. Applied uniformly: `dk_live` for derived
children handed to a kids list, `inner_live` for normalized subtrees freed
explicitly, `slice_live` for owned slices discharged by len checks before the
last `try`. The alternative — manual frees replicating the errdefer at each
error site — is what produced the gaps; the flag keeps one owner per exit.

The audit also has a blind spot worth naming: it counts, it does not name.
One outstanding allocation gave no site; staging `symDeriv` to return early
at each phase (parse, derive, norm) localized it in three compiles. That is
the debug method the meter asks for: bisect the pipeline, not the heap.

Related: [[frag-a-returned-managed-wants-errdefer-never-defer]] — the sibling
ruling for the opposite mistake (arming `defer` on a returned value), and
[[frag-a-dummy-slot-reset-is-an-allocation-in-disguise]] — same accounting
discipline: a "harmless" placeholder is still a live allocation the check
counts.
