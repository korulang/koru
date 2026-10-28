---
type: belief
id: frag-a-cache-salt-must-be-a-build-input
provenance: 2026-09-17 — asked why $TMPDIR/koru-regression-cache was 256 GB; measured 32.7 GB with no eviction anywhere, and an mtime salt minting a dead generation per compiler rebuild
ts: 2026-09-17
evolved: 2026-09-18 — from "the salt must be a build input" to "the key must be the backend's LINKED CLOSURE": content-hashing the source directory was complete but far from minimal
---

# A build cache's key must be minimal as well as complete (belief)

A key is *the set of files that determine the artifact*, and the two directions of
error are fatal in different ways. An omission serves a stale binary — the
neighbouring belief is that whole story, and it is why "complete" is the easy half
to argue for. An inclusion is the quiet half: it re-mints every cached backend for
an edit that cannot change one, and a cache that re-mints on every edit has
stopped caching, with no symptom but time and disk.

**The first form of this belief said only "a build cache's salt must be a build
input"** — true, and it fixed the half that was actively wrong (mtime is not a
build input; a rebuild is not an edit). Its implementation was a content hash over
the source *directory*: 269 files, of which a backend links 51. So it still
re-minted everything for an edit to `src/main.zig` — 8k lines of CLI the backend
never links — or to a `koru_std/*.kz` module, whose effect on a given test is
already carried by that test's emitted file, which the key hashes by itself.
Measured 2026-09-17: 5 of the day's 13 compiler commits touched nothing the backend
links, and each threw away every cached backend on the machine — ~2h of rebuild
CPU in one day, all-or-nothing per commit.

The belief, sharpened: **enumerate what the artifact actually embeds.** The poison
fragment already states this for completeness; it is equally the rule for
minimality. Here that set is the build graph's declared modules *plus* everything
reachable by relative `@import`, because Zig resolves those against the importing
file's own directory and they never appear in the module map — 12 files in `src/`
are reachable only that way. A directory walk is not a slice of that set; it is a
different, much larger set that happens to contain it.

Two disciplines fall out of the attempt, and neither is obvious in advance:

- **A textual walk has to lex.** This repo emits Zig as text, so `@import(`
  appears inside string literals (a `startsWith` argument in the visitor emitter)
  and inside comments naming libraries that are not dependencies. A walk that
  reads either invents edges; a walk that refuses on them is correct but can only
  be trusted if the refusal is loud. Getting this wrong is invisible — it looks
  like an import that happens to be unresolvable.
- **Unprovable means no key.** A closure that cannot be proven complete must key
  *nothing* and let the build happen, never key partially. Complete-or-nothing is
  the only shape that cannot serve a stale binary, and it makes the failure mode
  cost a rebuild instead of a miscompile.

Falsifiable edge: if a linked file could change without moving the key, this is
wrong — precisely what the relative-import gap would have caused, which is why the
walk follows them and a test pins that it does.

## Related

- `frag-a-backend-cache-keyed-on-mtime-can-serve-poison` — the same feature's
  completeness failure, where an unfaithful key served a poisoned backend. Read
  the pair together: one is "an unfaithful key serves wrong answers", this one is
  "an over-wide key serves no answers and says nothing". Both were the same
  mistake in different sites — the content-hash fix went to the key itself and
  left the salt behind for a month.

---

Extended 2026-10-14 (the third key had the same omission): the binary
backend cache (`backendCacheKey`, the `~/.cache/koru-backend-cache` lookup
the regression hot path lives on) carried NO ABI identity — a glibc-2.34
mint replayed verbatim under a `KORU_BACKEND_TARGET=...2.31` build and the
binary hard-failed at exec. The mint-manifest key
(`backendHashComponents`) had carried the env+ABI salt since the earlier
repair; the binary cache is a second key over the same artifact and the
salt never reached it — the same pattern this frag already records for
relative imports: a fix landed in the key that was *being looked at*, and
the sibling key kept serving wrong answers silently. Two keys over one
artifact is one belief: a salt that is not a build input poisons BOTH
sides of the divide — under-salted serves stale, over-salted serves
nothing.

Extended 2026-10-28 (a fourth site, found by replaying the fix on a
branch that predated it): the contract was documented — env var, cache
salt, emitted-build default — but this branch's tree carried none of it,
and its stage-D fallback (`host-build-zig`'s bare `zig build-exe -lc`)
read only `build:config`, so even a caller that pinned the env got a
native-target binary that could not exec. A contract that lives in one
lineage is not a contract: every consumer of the build graph — emitted
build.zig defaults, spawn-time -Dtarget, both cache keys, and each
stage's own fallback path — must honor the salt independently, because
each can be the one that runs.
