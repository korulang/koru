---
type: belief
id: frag-a-check-that-cannot-match-reports-clean
provenance: measuring a prose-invariant checker against 30 commits 2026-07-26 — two of seven pre-filters returned vacuous clean and were believed, until a sanity count showed one had been handed zero lines and the other was searching for a filename this corpus does not use
ts: 2026-07-26
---

# Silence from a check is not evidence until the check proves it can speak (belief)

[[frag-a-watcher-off-the-normal-path-is-not-a-wall]] found a guard that never
ran. This is its sibling with a different cause and an identical signature: a
guard that *does* run, on the right path, at the right moment — and cannot match
anything, because its pattern is wrong. Both report nothing. Nothing is exactly
what a clean tree reports.

The two instances that produced this were mundane, which is the point. A pathspec
of `:(exclude)status.json` written unquoted in zsh, where parens are glob
operators, silently narrowed a 160,000-line diff to zero lines — every filter
downstream of it then swept an empty string and found no violations. A separate
check searched for `expected_output` in a corpus that spells the file
`expected.txt`, and reported that no test expectation had been edited without an
accompanying compiler change. Both results were true sentences about nothing.

Neither is detectable by reading the check. Both read as careful work; one was
even reporting on a real and correctly-chosen invariant. The defect lives in the
gap between the pattern and the corpus, and that gap is invisible from either
side alone.

## Why this class is worse than a false positive

A finding that is wrong gets argued with. It arrives, it names a file and a line,
someone opens it, and it dies in a minute. The cost is bounded and the mechanism
that killed it — a person looking — is the mechanism the check exists to trigger.

A vacuous clean triggers nothing. It is consumed as confirmation, it accumulates
credibility with every run, and the longer it stands the more expensive it is to
doubt, because doubting it means re-deriving a result everyone has already
adopted. The check does not merely fail to help; it actively manufactures
confidence in proportion to how long it has been broken.

This is what makes the class dangerous specifically for checks that are *cheap
and numerous*. One expensive check gets watched. Forty cheap greps get trusted.

## What follows

- **Every mechanical check carries a positive control** — a pattern that MUST
  match, drawn from the corpus it searches. Zero hits on the control means the
  check reports BROKEN, never clean. This is the relationship `210_167` has to
  `210_166`, moved from the suite to the tooling.
- **A clean result must state what it saw**, not only what it did not find. A
  filter that reports "0 violations across 2,863 added lines" is falsifiable; one
  that reports "0 violations" is not, and the difference is one number that
  happens to be the exact number the broken versions could not have produced.
- **Silence is the weakest possible evidence and should be priced that way.** A
  check that has never once fired is not a check with a good record. It is a
  check with no record, and those are the same shape until something forces them
  apart.

## Open

Whether a control belongs in the check or in the corpus. Embedding a known
violation in the tree to keep a filter honest means carrying a deliberate defect
forever and trusting everyone downstream to recognise it as bait — the same
trade, and the same hazard, as a `MUST_ERROR` test.
