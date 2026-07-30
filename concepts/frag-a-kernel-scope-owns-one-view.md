---
type: belief
id: frag-a-kernel-scope-owns-one-view
provenance: surfaced probing whether std/kernel could express a Fast Multipole Method 2026-07-30; the question was "what does the triangle loop look like parameterized over two slices", and the answer was that there is no second slice to parameterize over
ts: 2026-07-30
---

# A kernel scope owns exactly one view, and until now it enforced that by losing the second one (belief)

The kernel family reads like a set of ops over data. It is not. It is a set of
ops over **one** view, and the view is not an argument to any of them — every op
finds it by walking up to the nearest enclosing `| kernel |>` branch and taking
that branch's binding. The set is ambient. Nothing in the surface says so,
because with one view there is nothing to disambiguate against, and one view is
all anyone has ever written.

That singularity is structural, not incidental. `init` carries
`claims_descendants`: it owns its whole subtree, so an `init` nested inside
another init's kernel branch never runs as a transform at all. Its dataset is
never emitted. Its binding is never substituted. The author's identifier walks
out of the kernel scope untouched and lands in the host.

## The interesting part is which failure you get

It surfaces as a host-level undeclared identifier — a Zig error, from a Koru
program, naming a Koru binding. That is already the wrong layer. But it is only
that loud because the two views happened to be spelled differently. Name both
`k`, the way anyone writing two kernels in a hurry would, and the inner ops bind
to the outer view: the program compiles, runs, and computes over the wrong
array. No diagnostic, and no reason for the author to look.

So this belongs to the family the no-fallbacks law is about, in its nastiest
form. Nothing was swallowed, nothing defaulted — a transform was silently
outranked by another transform, and the surviving program is well-formed. The
class is the same one `frag-transform-module-exposure-is-not-one-fault` names
from the other direction: a comptime name that never got minted, and a confident
program built on the absence.

## The validator was a denylist wearing an allowlist's message

The subtree check that should have caught this refused four control constructs
by name and admitted everything else. Its own diagnostic said the opposite —
that the scope allows only pairwise and self. Prose and code disagreed and the
prose was in the error message, which is the worst place for it, because the
error message is the only part an author ever reads.

Two things follow, and the second is the one worth keeping.

The first is that the gap had already been noticed and pinned twice, as
permanently-red tests carrying a hand-written script that echoed ASPIRATIONAL
FAILURE and exited non-zero. That is an honest instrument — it does not lie
about the state — but an unconditional failure pins nothing: it cannot tell the
day the behavior arrives from any other day. When the fallthrough closed, those
pins had to be rewritten from scratch to become pins at all.

The second: `std/kernel:step` was legal inside a kernel scope **only** because
of the hole. Nothing declared it; the fused-kernel path just happened to reach
it before anything refused it. So the hole was load-bearing, and closing it
required discovering what had been riding it. This is the general shape of a
permissive fallthrough — it does not merely fail to refuse the illegal, it
quietly grants the legal, and the two are indistinguishable from the code.

## What the refusal has to say

A construct refused inside a kernel scope must be named the way the author spelled
it. By the time the validator runs, an invocation has been resolved: bare `for`
carries `std.control`, and a user tor declared in the same file carries the file's
own module. Rendering the resolved path produces `std.control:for` and
`input:print-mass` — spellings that appear nowhere in the file being refused.
This is the same rule as a diagnostic never showing a tilde for a `.k`: the
compiler may know a longer name, but the author has to be able to find the thing.

## The design question this leaves open, which is Lars's

Iteration across two views has no kernel op. `pairwise` is the triangle
`i < j` over one set; the missing op is the rectangle over two. The commented
stubs at the foot of the library name `reduce` and `cross`, which is the right
pair — but `cross` cannot be built as "an op that takes another set" while the
set is ambient for every other op. The primitive that is actually missing is
**view multiplicity**: a kernel scope holding more than one named view. `cross`
is a small emitter delta once that exists, and a spelling nobody has written
until then.

The demand for it is not one algorithm's. Hierarchical n-body methods want
cross-set iteration three separate ways — box against box, particle against box,
particle against a neighbour set — and each is the same need. A surface built for
`cross` alone would be built for one third of the requirement.

## Open

- Whether view multiplicity is a change to `init` (stop claiming a descendant
  that is itself an init) or a distinct way to bind a view that does not go
  through `init` at all. The refusal deliberately does not imply an answer.
- Whether one-view-per-scope should stay the rule with multiple scopes composing,
  which keeps `claims_descendants` intact and makes `cross` a cross-scope op
  instead — cheaper to build, and it may be the wrong shape for the same reason
  the ambient view was.
- Whether the closed allowlist is now too closed. It admits exactly three ops
  because exactly three exist; the next op has to be added in two places, and
  nothing makes the author of that op notice the second one.

Related: `frag-transform-module-exposure-is-not-one-fault` (the same silent-name
class, and it already records that std/kernel's three ops all die at `init` —
this is why), `frag-std-store-design`.
