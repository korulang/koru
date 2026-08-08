---
type: belief
id: frag-an-outcome-branch-nobody-reads-is-not-a-report
provenance: `std/build:variants` reports failure through an `invalid-event` branch. Every documented example discards all three arms with `_`, so a key it could not resolve registered nothing and said nothing. Orisha's `~[build(linux)]` epoll selection had never taken effect. Found 2026-08-08; fixed and pinned as 370_013
ts: 2026-08-08
---

# An outcome branch nobody reads is not a report

Koru's answer to silent failure is that an event states its outcomes as
branches: `configured`, `skipped`, `invalid-event`. The caller must write an arm
for each, so a failure cannot be swallowed. That is the design, and it is a good
one — right up to the arm that reads `| invalid-event _ |> _`.

**Exhaustiveness forces the arm to exist. It cannot force the arm to mean
anything.** `_` satisfies the compiler and discards the report, and once one
example in a doc comment spells it that way, every program copies it — because
the arms are noise to a reader who has never seen the failure. `std/build:variants`
could not resolve `"orisha/pump:run"`, took `invalid-event`, registered nothing,
and the build succeeded. The line selecting Orisha's Linux pump had never once
taken effect, and nothing anywhere said so.

**This is worse than an unchecked return code, because it looks handled.** The
program visibly enumerates the failure. A reader auditing for swallowed errors
sees three arms and moves on. The shape passes every review that greps for
missing error handling.

Two things follow.

**A discard is a decision and deserves the same scrutiny as a value.** `_` on a
failure arm is the same act as `catch {}`, wearing the local idiom. Where the
failure is genuinely uninteresting, the arm should say why in three words, not
sit blank — the blank is indistinguishable from never having thought about it.

**A compile-time event that changes what the program MEANS should not report
through a branch at all.** A registration that does not happen is not an outcome
the caller might reasonably want to ignore; it silently changes which code runs.
`invalid-event` is a wall's worth of information delivered as a value. The right
shape for "you named an event that does not exist" is a diagnostic that stops the
build, and the fact that it was reachable at all — that the key spelling every
user would write was refused — was invisible for exactly as long as the branch
was the only place it was written down.

Related: [[frag-a-check-that-cannot-match-reports-clean]] and
[[frag-a-check-and-its-satisfier-must-enumerate-the-same-set]] — a family of
failures whose common shape is *the machine said something true and no one was
listening at the place it spoke*.
