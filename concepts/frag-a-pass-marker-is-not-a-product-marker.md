---
type: belief
id: frag-a-pass-marker-is-not-a-product-marker
provenance: found 2026-08-11, by the comptime mirror wall refusing a transform with no 115_* row
ts: 2026-08-11
---

# `@pass_ran` records that a pass VISITED a flow, not that it left code behind (belief)

The emitter exempts a `[transform]` flow from comptime filtering once
`is_transformed` holds, and `is_transformed` is true if the flow has an inline
body, a preamble, **or** the `@pass_ran` annotation. The comment at that site
reads *"the transform already ran and produced code"* — one clause too many. The
marker only says the pass reached the flow.

The two readings agree for every transform that produces a body, which is every
transform in the corpus but one. They diverge for a transform that returns
`.{ .transformed = .{} }` — *erase me, I have said everything at compile time*.
Under the wrong reading such a flow looks like it produced code, and its
invocation is emitted as a runtime call into a module that may have no runtime
half at all.

## Why it stayed invisible

In the entry file an erased flow is dropped from the item list before emission,
so it never reaches the exemption. Only a flow inside an **imported module**
survives to it. So the bug needs two conditions at once — a self-erasing
transform, declared outside the entry file — and until `std/vendor:bindings`
there was no transform in the corpus that erased itself at all.

That is the same shape as the mirror wall's own thesis: the entry file collapses
the file-derived name, the import-derived logical name and the emitted
`main_module` into one word, so nothing diverges until the subject lives
somewhere else. Here it is not a *name* that collapses but a *lifecycle* — "ran"
and "produced" are the same event in the entry file and different events in a
module.

## The general form, worth carrying to other markers

**A marker that records an EVENT is not evidence of a RESULT.** Whenever a
boolean is derived from "the pass touched this," ask what the pass does when its
answer is *nothing* — because "nothing" is exactly the case where touched and
produced come apart, and it is usually the case nobody wrote a test for.

Related: [[frag-a-partial-success-is-a-better-disguise-than-a-total-failure]] —
there two halves of one operation travelled by different routes; here one half
produced no output and the absence was read as output.

## How it was found, and what nearly buried it

The comptime mirror wall (`115_COMPTIME_MIRROR/COVERAGE.md`) refuses to let a
transform exist without a module-mirror test or a stated reason. Writing that
mirror is what surfaced this. The first response was to DELETE the failing test
so a board could be published clean — the fix was to write the test, not to
remove the thing that failed. See
[[frag-a-caveat-about-my-own-scope-is-dropped-work]]; the family is the same, the
disguise here was publishing hygiene rather than candour.

Pinned by `115_047_vendor_bindings_in_module`.
