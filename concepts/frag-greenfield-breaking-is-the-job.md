---
type: belief
id: frag-greenfield-breaking-is-the-job
provenance: migrated from koru/CLAUDE.md 2026-07-24
ts: 2026-07-24
---

# Koru has zero users, so breaking things is the job, not a hazard (belief)

There is no production, no shipped contract, no one downstream. This is not a
caveat on the work — it is the central operating fact, and it inverts the
instincts imported from production engineering.

- **Backward compatibility is technical debt here, not a virtue.** Keeping an old
  form working "so nothing breaks" when nothing depends on it buys nothing and
  costs plenty: a second way to do the same thing, a lie that compiles, a rule the
  language has outgrown still being honored. Delete it.
- **When the language moves, the old form must fail — loudly, at compile time.**
  A green test for a form the language has abandoned is not coverage; it is the
  old behavior silently surviving. **If a tightening does NOT break the old tests,
  something is wrong** — the enforcement didn't land. The breakage is the receipt.
- **No synonyms, no "keep both," no deprecation paths, feature flags, or staged
  rollouts.** Those are tools for protecting users. There are none. Change the
  language, fix the tests, move forward.
- **A window with no working `for` (or whatever) is fine** if the coherent
  replacement isn't built yet. Incoherent-but-working is worse than
  broken-but-honest. Flip first; build the replacement next.

The default when a change would tighten or replace a language form: enforce it
now, let the old tests go red, and treat the red as the migration to-do list.

## Why this needs recording — code cannot hold it

A green suite is silent about *why* it is green. It cannot distinguish "this form
is supported because the language wants it" from "this form still passes because
nobody dared break it." The stance — that a deliberate break is a successful
outcome and an unbroken old test after a tightening is a **failure signal** — has
no home in the working tree. Absent this, every session re-imports production
caution, reaches for a compatibility shim, and quietly re-accumulates exactly the
debt the greenfield position exists to refuse.

The companion belief that keeps this from becoming recklessness: the expensive
thing is a failure that teaches nothing — not failure itself. See
[[frag-tests-and-compiler-coevolve]].
