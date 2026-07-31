---
type: belief
id: frag-a-failure-that-looks-like-success-is-unfalsifiable
provenance: generalised 2026-07-31 after the same shape appeared four times in two sessions
ts: 2026-07-31
---

# The question to ask of any surface is "what observation would differ if this were broken" — and often the honest answer is none (belief)

Four separate defects across two sessions turned out to be one shape. In each,
the broken behaviour and the working behaviour produced **the same observation**,
so no amount of looking — by a person or by the suite — could have told them
apart.

- `koruc deps <module>` with the arguments swapped printed the toolchain's short
  green report and exited 0. `koruc deps` legitimately prints that report, so the
  version that discarded its argument looked identical to the version that had
  nothing to discard.
- `std/deps` seeded a hardcoded `zig` entry, so a collector returning zero
  results printed the same thing as a collector that worked
  ([[frag-a-hardcoded-value-disguises-a-collector-that-finds-nothing]]).
- `310_047` ran the command with `|| true` and echoed "Test passed". Green
  whether the command reported everything or nothing.
- `std/vendor` anchored on the wrong directory, and its unpinned-source test
  passed throughout — an unreachable lock path and a genuinely absent lock are
  the same observation
  ([[frag-a-transforms-filesystem-anchor-is-the-compilation-root]]).

## Why this is the useful frame

"Is it tested?" and "did I check it?" are both answerable yes while the property
is entirely unguarded. The sharper question is falsifiability:

> If this were broken, what would I see that I do not see now?

If the answer is "nothing", the thing is not verified, however green the board is
and however carefully the code was read. That question is cheap, it can be asked
of a test, a diagnostic, a probe, or a CLI surface, and it is the only one of
these that would have caught all four.

## Where the shape comes from

It is not carelessness — each individual decision was reasonable. It arises where
a surface has a **legitimate quiet state** that resembles its broken state:

- a report that is legitimately short
- a lookup whose "not found" is a real, handled condition
- a command that legitimately exits 0 having done little
- a default that is legitimately correct

Every one of those is a place where success and failure converge on the same
output. That convergence is what to design against — by making the quiet state
say *why* it is quiet ("no dependencies declared" rather than a bare list), and
by making tests assert content rather than exit status.

## The suite's own version of it

Noted the same week and unfixed: a filtered regression run naming three or more
tests silently matches zero and still prints `✅ ALL TESTS PASSED`. That is this
belief applied to the harness itself — the strongest possible instance, since it
makes every other check unfalsifiable at once. Worth treating as higher priority
than any single defect it might be hiding.
