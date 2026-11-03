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

---

**Evolved 2026-11-03 (string `<` — the defect without a lowering site).**
820_007's top-N demonstration hand-spelled a recursive byte comparator
in showcase code because `a < b` on strings doesn't lower — Zig refuses
`operator < not allowed for type '[]u8'` at Stage D. Same shape as the
`for`-bound cast: the host's type rule wearing a user-surface costume.
But this instance exposed the doctrine's boundary: the codegen rewrite
that would fix the glyph (`a < b` → `std.mem.order`) carries no type
oracle — it can only act on the syntactically decidable subset, which is
why `==` already rewrites only when a string *literal* is an operand and
`==` on two string-typed names is documented NEEDS_RULING. `<` sits in
that same unserved class: refusing loudly, not silently wrong, and the
fix is a ruling about a type oracle, not a one-place emit change.

So the surface answer shipped namespaced instead: `std/string:cmp`
(`| lt | eq | gt`, the `std/num:cmp` shape, pure-Koru recursion over the
slices, `string<*>` operands per the string frag's pure-read ruling).
Pinned by 610_025; 820_007 respelled onto it. The rule gains a second
half: **when the glyph fix needs an oracle that doesn't exist, the
namespaced tor is the ruled surface — not a workaround to apologize
for — while the glyph question waits on Lars.** A future `<`-on-strings
lowering would occlude this only for call sites that prefer the glyph;
the tor stays the explicit-order spelling either way.
