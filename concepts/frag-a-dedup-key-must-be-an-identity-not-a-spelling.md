---
type: belief
id: frag-a-dedup-key-must-be-an-identity-not-a-spelling
provenance: `~import mylib` resolved to `<dir>`; the `mylib/index` import the compiler synthesizes for `~import mylib/helper` resolved to `<dir>/index.kz`. Dedup keyed on the resolved path, so one module was imported twice and every declaration in its index emitted twice. Found 2026-08-08 wiring orisha's pump seam; fixed and pinned as 110_030
ts: 2026-08-08
---

# A dedup key must be an identity, not whichever spelling arrived first

A cache, a visited-set, a "have I already loaded this" guard — each is only as
correct as the claim that two entries with different keys are different things.
When the key is a *spelling* rather than an *identity*, the guard is silently
partial: it catches the duplicates that happen to arrive spelled the same and
waves through the ones that don't.

koruc's import loop guarded on the resolved path. A package imported as a
directory resolved to `<dir>`; the same package reached through its own index
file resolved to `<dir>/index.kz`. Two strings, one module — and the compiler
generates the second spelling itself, from the first, whenever a package's index
imports a sibling. So the guard could not have been more precisely wrong: the
one duplicate it was guaranteed to face was the one it could not see.

**A partial guard is worse than none, because it is a claim.** The debug log
printed `DEDUPLICATION: Skipping duplicate import` for every std module, in
volume, all correct. Reading that log builds the belief that dedup works. It
does — for the shape that happens to spell itself consistently.

The downstream damage is the part worth remembering. Nothing checked "one module
declaration per source file"; the emitter simply groups declarations by logical
name and writes them all into one struct. So a module that arrived twice put its
entire declaration surface in twice, and the failure surfaced as `duplicate
struct member name 'std'` — which reads as a submodule's host line colliding
with its parent's, an entirely different bug in an entirely different pass. **A
broken identity does not fail where it breaks; it fails wherever the duplicate
is finally noticed**, and it wears that layer's vocabulary.

Two rules fall out. **The key must be a canonical form**, computed by a function
that every construction site of the thing routes through — here, normalizing a
directory to its index file. And **the invariant should also be enforced where
it is depended on**, not only where it is established: the emitter now refuses a
second module declaration for a file it has already emitted, so an identity bug
anywhere upstream stops being an emitted-twice bug downstream.

Related: [[frag-a-check-that-cannot-match-reports-clean]] — same shape, a guard
whose key cannot match the thing it is meant to catch, reporting success.
