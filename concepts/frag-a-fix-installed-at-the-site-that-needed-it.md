---
type: belief
id: frag-a-fix-installed-at-the-site-that-needed-it
provenance: the last two reds of the 115 mirror wall, 115_004 and 115_036; both were correct code that had been installed one level too low, and both had been green for months from the entry file
ts: 2026-08-02
---

# A fix installed at the site that needed it is a fix that only works there (belief)

Two of the last three module-mirror reds were not missing code. The code
existed, was correct, and had been exercised for months. It had simply been
written into the one place that first needed it, and the thing that decides
whether that place is reached had nothing to do with the property being
protected.

**The `for`-capture uniquifier.** The `~for` template renders a hardcoded
`for (..) |__koru_item|`, so two instances in one Zig function collide. The
emitter renames each instance's capture — inside ONE branch of a three-exit
function, the branch taken when the invoked event declares effect arms.
Which exit a body takes is decided by inline eligibility. So the same nested-`for`
program was safe compiled from the entry file and a Zig shadowing error compiled
from inside a module: not a module bug at all, a *reachability* bug that a module
happened to expose. The property — "this rendered body owns its capture name" —
belongs to the BODY, so it belongs at the function's entry, before any branch.

**The scope registry.** `register` emits its descriptor and dispatcher beside
the events they name, which is the only place they can be — Zig gives a sibling
struct no path to the entry struct. The comptime scan that discovers them read
`root.main_module` and nothing else. A scope registered in a library was
therefore invisible, and invisible *quietly*: the program compiled, ran, and
took its `| scope-not-found` arm. A well-formed answer built on an empty
registry.

## The tell, and it is available before the bug

Both fixes read as complete because each site's own reasoning is sound. What
gives them away is a mismatch of *quantifiers*: the property is universal ("every
rendered body", "every registry in the program") and the installation is
existential ("this branch", "this namespace"). When a comment justifies a fix by
describing the case that motivated it, ask what else is in the universal — the
answer is usually "one other exit" or "one other container", and it is usually
already in the tree.

Concretely, for anything that guards a name or discovers a declaration:

- **Guards go at the entry**, not in the branch where the collision was first
  seen. A three-exit function with the guard in one exit is two latent bugs.
- **Discovery walks name a set, not a place.** `root.main_module` is a place;
  "every namespace the emitter writes" is the set. If the walk hardcodes one
  container, the second container is a matter of time.

## Why this class survives so long

Because the entry file collapses the distinction. Every one of these was green
for months, exercised constantly, by programs that could not tell the difference.
That is the same collapse
[[frag-transform-module-exposure-is-not-one-fault]] identifies for names — and it
is now clear the collapse hides *reachability* too, not only naming. The 115 wall
finds both, and cannot tell them apart until each red is chased to its cause.

## The one that is not this

`115_020` stayed red and is not a module finding at all: its original, `690_069`,
is red for the reserved row ordinal. A mirror whose original is red says nothing
about the boundary. That check is cheap and belongs before any diagnosis on this
wall.
