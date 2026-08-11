---
type: belief
id: frag-only-sabotage-separates-a-pin-from-a-decoration
provenance: writing 310_122 (a Koru program that allocates, built for x86_64-freestanding) on 2026-08-11 — the pin passed with the emitter fix reverted, and only reverting it revealed that
ts: 2026-08-11
---

# A pin is a decoration until sabotage has failed it — including a pin that names the trap (belief)

310_122 exists because a program that never allocates never analyzes the
allocator: Zig only checks a function body something reaches, so the allocator
spine sat unexamined in every emitted program on every target. Its own header
comment says exactly that, at length, and names the unikernel example as the
program that gets away with it.

Its first version then passed with the fix reverted.

The mechanism was the same one, one level up. The pin needed an entry point to
satisfy the ELF linker, and the entry it got merely trapped. That left the
emitted flow unreferenced, so the allocating body was never analyzed and the
assertion never ran. Every word of the comment was true and the test underneath
it measured nothing.

**Naming a trap does not confer immunity to it.** The comment demonstrates
understanding at the level of *the code under test*; the trap recurred at the
level of *the harness reaching that code*, which the author was not thinking
about because it felt like plumbing. Understanding is not distributed evenly
across the parts of a test, and the parts that feel like plumbing are where it
is thinnest.

## What this rules out as evidence

Reading the test would never have found it, and neither would running it —
it was green, in the right category, with a plausible name and a defensible
body. There is exactly one operation that distinguishes a pin from a
decoration: **remove the thing it claims to hold and watch it fail.** A pin
that has only ever been observed agreeing with a working system carries no
information about a broken one.

This is [[feedback_calibrate_a_check_by_sabotage]] applied to the test corpus
rather than to a script, and it is a sharper case than the original: a gate
that has never refused anything at least *looks* suspicious. A green pin looks
like exactly what you wanted.

## The sibling constraint that made this expensive

Sabotage requires editing compiler sources, and a worktree does not isolate
those — `/usr/local/lib/koru/src` symlinks to the main checkout, so a
deliberately broken emitter is broken for every session on the machine,
including boards running elsewhere. Calibration is therefore a *timed* act,
and when the window closes mid-calibration the honest fallback is to measure
the same assertion against a hand-written copy of the emitted text in the same
build mode — which answers the question without holding the shared tool
hostage. What is NOT a fallback is declaring the pin calibrated because the
corrected version looks better than the version that failed.

## The test this leaves behind

Before a pin counts: state which edit it forbids, make that edit, and record
what it printed when it failed. If that sentence cannot be written, the pin is
documentation — possibly true documentation, but it will not stop anything.

Related: [[frag-a-vacuous-check-can-be-vacuously-sound]] (a check whose domain
is empty by construction), [[frag-a-red-pin-is-unfalsifiable-documentation]]
(the mirror: a pin that has never been green).
