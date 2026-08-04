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

The sharpest instance is the one found last, because there the surface does not
merely fail to reveal a problem — it **asserts the opposite**. `downloads.k` does
not compile; a plain build fails on KORU161 and produces nothing. Yet
`koruc downloads.k deps` printed `✓ Built executable: a.out` and exited 0. The
line was emitted whenever the backend exited cleanly, with no check that any
executable existed, so a command run — which legitimately never reaches Stage D —
reported a successful build of a broken program. Three untruths in one line: it
built nothing, the thing it named does not exist, and the program cannot build at
all.

## Why this is the useful frame

"Is it tested?" and "did I check it?" are both answerable yes while the property
is entirely unguarded. The sharper question is falsifiability:

> If this were broken, what would I see that I do not see now?

If the answer is "nothing", the thing is not verified, however green the board is
and however carefully the code was read. That question is cheap, it can be asked
of a test, a diagnostic, a probe, or a CLI surface, and it is the only one of
these that would have caught all four.

## It does not only hide bugs — it manufactures false beliefs

The harness printed `Running 0 tests... ✅ ALL TESTS PASSED` and exited 0 when a
filter matched nothing. Chasing that, I concluded the harness silently dropped
filtered runs of three or more tests, reported it as the highest-priority
toolchain defect, and repeated it across several messages.

It was not true. zsh does not word-split unquoted parameter expansions, so a list
in `$VAR` arrived as one filter matching nothing. The harness matched correctly.
The green verdict over zero tests was the only thing standing between me and that
explanation — had it said "no tests matched", the shell mistake would have been
obvious in seconds.

So the cost of an unfalsifiable success is not bounded by the bug it conceals. It
also produces confident wrong diagnoses in whoever reads it, which then get
reported, prioritised, and acted on. A surface that cannot look broken will
eventually make someone describe a defect that does not exist.

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

## The corpus's own version of it

Turned on this file's neighbours the question becomes an intake gate rather than a
design rule, and it catches a failure the membrane's other rules let straight
through. Intake bans *duplication* — a fragment restating code, a test, a count.
It says nothing about *platitude*, and a belief hedged until no observation could
contradict it satisfies every ban while carrying nothing.

So ask it of a fragment before writing one: what future observation would
`correct` this? No answer means it is not a belief, it is decoration. `correct` is
the verb this corpus exists for — the ledger of where code-as-spec was wrong — so a
fragment that can never be corrected is excluded from the corpus's own purpose
while passing every rule at the door.

The pressure runs one way, which is why this needs a gate and not merely a
mention. Hedging a claim makes it likelier to survive contact with the world, and
a claim that survives everything taught nothing by surviving. That is the trade
[[frag-a-red-pin-is-unfalsifiable-documentation]] names one level down: there an
explanation escapes checking because the test is red, here a belief escapes
checking because it asserts too little to ever be caught out. Both are prose in
something else's clothes, and the defence is procedural for the same reason — no
assertion can check whether a belief is capable of being wrong.

Surfaced 2026-08-04 from the opposite claim: a paper arguing the best hypothesis
is the *weakest* one consistent with the evidence. That is right for predicting
and inverted here, because a belief in this corpus is not kept in order to be
right. It is kept in order to be caught out.
