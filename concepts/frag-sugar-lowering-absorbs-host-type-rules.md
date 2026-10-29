---
type: belief
id: frag-sugar-lowering-absorbs-host-type-rules
provenance: dice challenge on X — the Koru entry needed `for(0..@as(usize, @intCast(n)))` because the `for` lowering spliced range bounds verbatim into a Zig usize loop; the cast in showcase code was a lowering defect, not a user problem
ts: 2026-10-29
---

# Sugar lowering absorbs the host's type rules

A keyword whose lowering splices into host constructs owns the host's
type constraints. `for` lowers to a Zig range loop, and Zig range
bounds are `usize` — so for a long stretch every Koru `for(0..n)`
over an `i64` bound refused at the zig stage and pushed an
`@as(usize, @intCast(n))` into user code. That is the host's rule
wearing a user-surface costume: the caller had to know what `for`
lowers to in order to call it.

The lowering already extracts `__range_lo`/`__range_hi` (the
`[parallel]` and `reverse-each` paths bound them as `usize` consts) —
the serial `each` path just spliced `{{ expr }}` verbatim. The fix is
one place: emit `@intCast` where the bounds are extracted, at all
three paths. A `usize` bound is an identity cast; an `i64` bound
converts; a negative bound now panics at runtime instead of refusing
at compile — the trade is honest because a negative range bound was
never a program the sugar could mean.

Corollary for the next wart of this shape: when a caller-side cast
shows up in *showcase* code (the dice entry on X needed one), treat
it as a lowering defect first and a user problem never.
