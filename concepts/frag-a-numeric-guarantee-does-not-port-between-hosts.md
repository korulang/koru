---
type: belief
id: frag-a-numeric-guarantee-does-not-port-between-hosts
provenance: 690_270 — the JS handle encoding silently aliased two live rows past 2^21 generations, while the Zig one was exact; the stdlib comment asserted the two were equivalent
ts: 2026-08-08
---

# A numeric guarantee does not port between hosts just because the expression does (belief)

`std/store` gives every row a handle packing three fields into one integer:
the sparse slot low, the issuing store's brand above it, the slot's generation
in the high half. On the Zig lane that is shifts and masks on sized integers,
and the generation bump is spelled `+%=` because a plain `+=` on a `u32` is a
compile error. On the JS lane there are no 64-bit bitwise operators, so the
*same layout* is assembled by multiplication and the bump was spelled `+ 1`.

The comment that justified the difference had the reasoning exactly backwards:

> JS has one number type and no wrapping operator; the counter is compared for
> equality only, so `+ 1` is the same guarantee.

Every clause of that is true and the conclusion is false. The counter *is* only
compared for equality — but it is also **multiplied into the handle**, and
`generation * 2^32` is exact only while the product stays inside a double's
exact-integer range. 2^21 × 2^32 is 2^53. One generation past that, the slot
and brand in the low bits are rounded away: two different *live* rows encode to
the same handle. The mechanism built to make a recycled slot safe is the one
that makes it unsafe.

**The general belief.** When one construct is lowered to two hosts, the thing
that must agree is not the expression but the *guarantee*. Zig's `+%=` and JS's
`+ 1` are both "increment a counter"; they are not both "keep this encoding a
bijection", because the hosts disagree about what a number is. Any time a value
is packed, hashed, shifted, or scaled on more than one host, the porting
question is what the arithmetic **promises**, and that has to be re-derived per
host rather than translated.

**Two things made it survivable for as long as it did, and both are worth
keeping in mind.**

The first is that the failure does not look like corruption. A handle that no
longer decodes fails its brand check, so `take` answers its ordinary `| empty`
branch — the row is simply never removed. Nothing traps, nothing prints. The
store keeps a row the program believes it took. A leak that presents as a
successful removal is far quieter than a wrong row, and it is why 690_270 pins
a *live count* rather than comparing values through two handles. The first
version of that pin did compare values, and it passed with the fix removed.
**A pin aimed at the wrong symptom is indistinguishable from a passing test.**

The second is an asymmetry in the walls around the same encoding. Capacity past
2^24 refuses loudly. More than 255 stores refuses loudly. The generation
ceiling — the only one of the three that **grows at runtime**, and therefore the
only one no author can inspect their program and rule out — had no refusal and
no test. Bounds on things that grow deserve *more* guarding than bounds on
things declared once, and they tend to get less, because the declared ones are
the ones you are looking at when you write the check.

**Open.** The fix wraps the JS counter at 2^21, which matches the *kind* of
guarantee Zig has at 2^32 but not the size. Nothing yet detects that a program
has recycled one slot two million times, on either host — the wrap is silent by
design on both. Whether a store should be able to notice that, and say so, is
unanswered.

Relates to [[frag-a-fix-lands-in-one-lowering-path]] and
[[frag-two-lowerings-share-one-contract]] — the same disease at the level of
arithmetic rather than control flow, and the reason it hid longer is that the
two lowerings here were not merely both present, they were accompanied by prose
asserting they were equivalent.
