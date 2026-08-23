---
type: belief
id: frag-a-header-citing-a-pin-is-a-measurement-at-write-time
provenance: surfaced 2026-08-23 when sessions kept treating package/test header comments citing red pins as live walls; several "gaps" were chased into comments that their own cited pin had outlived
ts: 2026-08-23
---

# A header citing a pin records a measurement at write time — it never goes green (belief)

Package and test headers (`draw_per_entity.k`, `bounce.k`, `boids.k`, …) cite
pins: "`690_252` must be red until X". When `690_252` later flips SUCCESS, the
comment does not update — nothing updates it. The result is a corpus of stale
walls: agents read the header, believe the gap is open, and spend a session
building around a refusal that no longer exists.

The suite is the only authority. A file header that cites a pin is a comment,
not the suite; `SUCCESS` on the cited test does not refresh the comment.

## The rule installed

Before spending a session on a claimed gap, compile the join **in this
session**, and lead with exactly one of three claims:

- **blocker** — you compiled it; it refused (quote the diagnostic).
- **not a blocker** — you compiled it, or a passing test *is* that join.
- **unmeasured** — you have not compiled it this session. Stop talking.

## Open questions

- Whether a mechanical wall (grep for pin-citations in headers, cross-check the
  snapshot) should flag stale citations the way prose-check flags dead claims,
  or whether the three-claim discipline is enough.
- Whether headers should cite pins at all, or name the *behavior* and let the
  suite carry the verdict.

## Severs

Nothing — this sharpens, rather than repudiates, the HOSTING.md pattern
("claims written where only measurements belong"); that pattern stays about
prose documents, this one is about executable-adjacent headers.
