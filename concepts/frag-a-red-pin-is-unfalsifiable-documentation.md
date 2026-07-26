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

## A diagnostic is not the compiler's belief

The specific way a wrong explanation gets written: a diagnostic is read as
evidence of what the compiler thinks, when it is only evidence of what one code
path prints. The message and the behaviour it describes are separate
implementations of the same question, and nothing makes them agree.

KORU030 is the worked case. Its candidate list — "Call one of: …" — is built by
SIGNATURE, naming every tor whose input accepts the obligation. The
auto-discharge inserter builds its own list by EFFECT, keeping only calls that
actually settle the debt. For one program the two disagree outright: the
message offers a conserving tor, the inserter reports that nothing accepts the
obligation at all. `330_118` was written off the message, and pinned a fault
that does not exist — auto-discharge had exactly one candidate and inserted it
correctly.

So a diagnostic is a claim to verify, never a premise to build on. When it says
what the compiler will do, go make the compiler do it and watch. The cost of
skipping that is not a wrong sentence in a test comment: the wrong reading here
survived into a design discussion and shaped it for hours before a question
about the premise brought it down.

This is the same shape as duplicate implementations concealing a coverage gap
([[frag-the-minimal-test-of-a-wall-cannot-test-its-reach]]) — two answers to one
question, with the prominent one wrong. The difference is which one you meet:
there the working path masks the broken one, here the *printed* path masks the
working one, and printing is the only face a user ever sees.

## Open

Whether a red pin should be *required* to carry its minimal reproduction, or
whether that is what these pins already are when written well. There is also a
tempting mechanical half-measure — flag a pin that has been red across many
snapshots as due for re-derivation — but staleness is not the fault. `330_074`
was mis-framed from the day it was written, and a fresh mis-framing is exactly
as harmful as an aged one.
