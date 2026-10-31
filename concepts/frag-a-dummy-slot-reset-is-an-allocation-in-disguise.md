---
type: belief
id: frag-a-dummy-slot-reset-is-an-allocation-in-disguise
provenance: the sym rung leak-checked red on every path; the "harmless" decZero written into moved slots was itself a live allocation the success path never freed
ts: 2026-10-31
---

# A dummy slot reset is an allocation in disguise (belief)

When a move-out leaves a hole in a list that a later `errdefer` walks, the
tempting fix — overwrite the moved slot with a "harmless" zero/empty value —
is wrong twice over.

First, zero is not free: `std.math.big.int.Managed.initSet(alloc, 0)`
allocates its default limb capacity even for the value zero. Every dummy
`Dec{0}` written into a moved slot is a live allocation the success path
never frees — the fix leaks exactly what it pretends to prevent.

Second, the dummy itself is a lie: the slot no longer holds a real value, so
any code that walks the list (not just the errdefer) must know about the
convention.

Two disciplines cover it cleanly:

- **Borrow, don't move.** If consumers only need to *read* the item, pass a
  `*const` and have them clone what they keep (`termWithCoeff` in std/sym:
  the term is a fresh tree; the bases/coeffs lists keep owning their items
  and one `defer` frees them on every path). Moves out of shared lists make
  every later error path a double-free candidate.
- **Progress-indexed errdefer.** When a loop genuinely consumes list items
  one by one, `errdefer for (items[fi..]) nodeFree(...)` with `fi` bumped
  immediately after the free/move keeps the cleanup range exact — no dummy
  needed, no double-free on a mid-loop error.

The pattern generalizes past bigints: any "reset the moved slot" idiom
assumes the reset value is cheap and inert. If constructing the inert value
allocates, the reset is a leak wearing a fix's clothes.

The converse ruling (supgen rung, 2026-10-31): **assigning into an
initialized slot is a move — deinit the old value first.** `serZero`
pre-fills every coefficient with a live `0/1` Rat, so `s[i] = f(...)` on top
of it silently leaks the zero. Same shape, opposite direction: the slot was
already owned. Either allocate the buffer *undefined* and fill, or
`ratDeinit(&s[i])` before every overwrite. Both directions of the trap live
in the same file now: the dummy-reset leaked what it pretended to prevent;
the pre-fill leaked what it pretended to initialize.

Parents: frag-a-returned-managed-wants-errdefer-never-defer
