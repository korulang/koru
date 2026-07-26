---
type: belief
id: frag-a-red-pin-is-unfalsifiable-documentation
provenance: 330_074 read as an obligation defect for weeks; a plain-payload probe reproduced it with no phantom present
ts: 2026-07-26
---

# A red pin's stated cause is checked by nothing (belief)

A green test is continuously falsified. Its claim is re-tested on every run, and
the moment reality stops matching it the suite says so. That feedback loop is the
whole reason we prefer a pin to prose.

**A red test has no such loop.** Its *failing* is asserted every run; its
**explanation** — the title, the comment, the cause it names — is asserted by
nothing at all. It can be wrong on the day it is written, or drift as the
compiler moves underneath it, and the suite stays exactly as red either way.
Red pins are prose wearing a test's clothes, and they inherit prose's failure
mode while looking like they cannot.

The failure is worse than ordinary stale prose, because a red pin *earns
attention*. It is the thing a future session opens first, and its title is the
frame they start reasoning inside. `330_074` says an obligation carried across a
label-fold back-edge, so the obligation machinery is where a reader goes. The
defect is in capture emission and reproduces with no phantom anywhere in the
file — the title had been pointing away from the cause for as long as it had
been red, and being red is precisely why nobody caught it.

## What follows

- **Re-derive a red pin before trusting it.** Its failure is evidence; its
  explanation is a hypothesis someone had once. Reproduce the fault from the
  minimal shape before adopting its framing — the reproduction is cheap and the
  wrong frame is expensive.
- **A pin holding several variables cannot name its cause**, and being red is
  what lets it get away with the claim. `330_074` varies three things at once
  (obligation, inline-bind spelling, prefix-before-fold); the one doing the work
  is the one its title does not mention. `210_166` isolates that variable and
  nothing else.
- **The instinct to widen the instrument does not reach this one.** Where
  [[frag-a-pin-constrains-text-not-location]] found an axis the harness could not
  *express*, this is an axis nothing can express: no assertion can check that a
  comment's account of a bug is true. The defence is procedural, not mechanical —
  which is why it belongs here rather than in the harness.

## Open

Whether a red pin should be *required* to carry its minimal reproduction, or
whether that is what these pins already are when written well. There is also a
tempting mechanical half-measure — flag a pin that has been red across many
snapshots as due for re-derivation — but staleness is not the fault. `330_074`
was mis-framed from the day it was written, and a fresh mis-framing is exactly
as harmful as an aged one.
