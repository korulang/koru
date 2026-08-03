---
type: belief
id: frag-a-corpus-exercises-its-authors-idioms
provenance: binding libcurl's multi interface broke the pipeline surface four ways in one sitting, on the oldest and most-exercised construct in the language
ts: 2026-07-27
---

# A test corpus exercises the idioms of whoever wrote it (belief)

Coverage is usually read as a property of the *code* — which paths run, which
branches are taken. The more useful reading is that a corpus records **how its
authors write**, and is silent about every other way the same construct can be
spelled.

Koru's pipeline surface is the oldest and most exercised thing in the language.
Writing the first program that chains a real library through several steps broke
it four ways in one sitting: `//` inside a mid-chain string taken as a comment, a
multi-line chain swallowing the arms that follow it, a chain step's result not
threading to the next, and a re-bind refused by the host compiler rather than
this one.

None of those are exotic. They are what a *consumer* writes on day one: a URL, a
pipeline long enough to want line breaks, a handle carried from step to step. The
corpus is full of chains — with numeric payloads, on single lines, at flow heads,
because that is what a compiler author writes when demonstrating that chaining
works.

## Why this is not just "write more tests"

The gap is invisible from inside. Every one of those shapes looks obviously
covered when you already know the idiom the tests use; the missing spellings are
missing precisely because nobody thought of them as spellings. You cannot review
your way to them — the reviewer shares the idiom.

What *does* find them is a consumer with their own habits, which is the real
argument for application clusters as instruments
(`frag-milestone-suites-are-instruments`). They do not find bugs because apps are
complicated. They find bugs because the app author writes differently from the
compiler author, and difference is the entire mechanism.

An app that merely re-plays the corpus's idioms would find nothing.

## What follows

- **Prefer a consumer's spelling to a minimal one** when adding coverage to a
  well-worn construct. The minimal spelling is almost certainly already there.
- **A construct's bug density is unrelated to its age.** Most-exercised and
  best-tested are different properties, and the first is routinely mistaken for
  the second.
- **When an app breaks something old, expect a cluster, not an instance.** Four
  faults in one sitting on one construct is the signature of an unexercised
  idiom rather than four coincidences.

## It caught the author of this belief, the same night

KORU112 shipped with a check that read a module's `host_line` items for
declaration names. Host lines include the BODIES of host-level `fn`s, so a
local inside one — `const msg` inside `curlError` — read as a module
declaration, and the curl lift stopped compiling.

The full suite passed clean on that version. Twice. No module in the corpus has
a host-level `fn` whose locals share a name with anything an effect-branch proc
mentions; the real library is the only thing that does. It was found by Lars
running the example by hand, minutes after this belief was written down — and
after a new wall had been verified entirely against the corpus the belief says
is silent about consumer idioms.

Which sharpens the practical form. It is not enough to *believe* a corpus is
idiom-bound. **A new wall must be exercised against something outside the
corpus before it is trusted** — the lifts, an example, anything with a different
author. A green suite says the wall does not contradict the idioms already
present, which is a much weaker statement than it looks.

## A workload someone else designed is an idiom generator we do not control

The sharpest instance so far came from `ecs_bench_suite`'s `simple_iter` —
`pos += vel` over 10k rows, rust-gamedev's program, not ours. Twenty minutes of
pointing it at `std/store` surfaced four faults behind a 1203-test green board,
the first of which is a plain spelling gap: **every `stored` site in the corpus
writes exactly one column.** 690_111 advances `b.x` alone across an all-f64
container; 695_001 chains single-field writes with `|>`. A compiler author
demonstrating write-back writes one field, because one field demonstrates it.

An ECS integration step is three fields under one arm. The plural block —
`stored { e.px: …, e.py: … }` — had never been asked for, and it refuses with
KORU161 quoting a mangled internal name (pin 690_118).

This upgrades the practical form again. Application clusters are instruments
because the app author writes differently; a **borrowed benchmark** is stronger
still, because its workloads were fixed before we existed and cannot drift
toward what we find convenient. Its value here was never the number — the number
is still unmeasurable — it was the idioms.

## The instrument points both ways (second sitting)

Replaying the six remaining ecs_bench_suite workloads (690_119–125) taught the
inverse lesson. A corpus is silent about spellings its authors never wrote — and
a GAP BOARD is silent about rungs that have landed since it was written. The
ecs-store README declared every workload absent; most of their shapes compile
today, because rungs land against the corpus's own tests and nobody re-runs the
prose. A prose capability claim decays toward ABSENT exactly as prose coverage
claims decay toward PRESENT; the pin is the only instrument that moves with the
compiler in both directions. So when a board says "can't", the first move is to
point the workload at the compiler anyway — the pin either flips the board or
lands the gap in the suite where it stops rotting.

The sitting also sharpened the original finding: the green region around a
refusal is exactly as wide as the test that pins it. A moved line break, a third
field, a parenthesis — each is a different program to the compiler and the same
program to its author (690_125 against 690_118). Pinning the consumer's layout
of a shape, not only its minimal spelling, is the cheap defence.

## Open

Whether this can be attacked directly — generating spelling variants of existing
fixtures (line breaks moved, literals substituted, bindings renamed) and checking
the suite still passes. It would have caught at least two of the four
mechanically. The risk is a pile of generated tests nobody can read, which is its
own kind of rot; a generator that produces *failures* to triage, rather than
tests to keep, may be the better shape.

## A gap named inside a report decays the same way (third sitting)

The second sitting recorded that a gap BOARD decays toward ABSENT while the
compiler moves under it. The same decay happens one level down, faster, and
with less to catch it: a gap named inside an agent's report, repeated into a
design conversation, and treated as a premise before anyone probed it.

The `heavy_compute` lane listed "no local scalars in a sweep arm" among its
gaps — accurately, for what it had tried. That got restated here as "the
language has no local binding, so every intermediate must become a store
column", which made a temporary column look structurally forced and turned a
~17% per-column cost into an apparent language limitation. Lars pushed back on
the framing rather than the cost, and the probe took twenty minutes: a sweep arm
chains and binds today, and the bind reaches a `stored` write (690_130/131).
Nothing was missing.

The tell was available the whole time and nobody read it as one: **138 `stored`
sites in the corpus and zero took a value from a chain binding.** That is the
signature of an unexercised composition, which this belief already says to read
as "untested", not "unsupported". It was read as the latter.

- **A gap in a report is a hypothesis with a citation, not a finding.** It
  reports what one agent tried, and its silence is about that attempt.
- **Zero-of-N is the strongest available prompt to probe**, and it is cheap to
  compute. Where a construct is used N times and a neighbouring composition
  appears zero times, that is the experiment, not the conclusion.

## One RED user is worse than zero users (fourth sitting)

The third sitting closed on "zero-of-N is the strongest available prompt to
probe". There is a weaker-looking signal that is strictly more dangerous, and
it cost this belief a silent miscompile for twenty-one days: **ONE-of-N, where
the one is red.**

A `|>` chain in a subflow body written on the line after `=` kept only its
FIRST step. Every tail step was discarded by the parser — no error, no warning.
The same chain returns 12 written inline and 6 written across two lines
(210_200 now pins both). The `=` subflow body was the single place that did not
apply the rule the parser states about itself: "multi-line pipe chain parses
EXACTLY like its inline spelling … ONE rule for `|>` chains everywhere."

Exactly one file in the corpus wrote that spelling — 110_006's `helper.kz` —
and it had been red since Jul 12. That is why nobody probed:

- **Zero-of-N advertises itself as unexplored.** It offers no explanation, so
  the honest reading is "untested", and this belief already says to probe it.
- **One-red-of-N supplies a FALSE explanation.** The shape has a witness, the
  witness has a verdict, and the verdict comes with a plausible cause attached
  (`KORU100 unused binding 'd1'` — a binding error, in a language with a
  binding checker). The red looks *accounted for*. A test that is already
  failing for a stated reason is the best hiding place in the repo, because the
  reason is load-bearing: it stops the search.

The diagnostic was true of the tree the parser built and false of the program
the author wrote. **A wrong tree makes an honest checker lie** — and the lie is
well-formed, points at real source, and names a real rule. When a checker
accuses source that plainly satisfies it, suspect the tree before the checker;
the reflex is to argue with the rule.

What follows, and it is cheap:

- **A red test's stated cause is a claim, not a diagnosis** — the same status
  this belief already assigns to a gap named in a report. Nothing re-derives it
  after the first sitting, and it decays exactly the way a gap board does.
- **Count users of a SPELLING, not a construct, and read the verdict column.**
  One-of-N where the one is red should rank ABOVE zero-of-N on the probe list.
- **Pin the value, never the diagnostic, when the tree is in question.** 210_200
  asserts 12 and 8. Had it asserted "no KORU100", the fix that deleted the
  false diagnostic without restoring the dropped call would have passed it.

## The break was at the program's EDGES, not in the workload (fifth sitting)

Every sitting so far read this belief as being about the construct under test:
the consumer spells the *feature* differently. Pointing the borrowed ECS
harness at Koru broke something the workload never touches.

A foreign harness does not only hand you a workload. It hands you a **contract
at the program's edges** — a flag grammar to accept, one machine-readable line
to emit, a checksum whose only job is to be read by something that is not a
human. The Koru entry's first failure was not in a sweep. It was that
`print.ln` cannot print a literal `{`: the message reaches the host's formatter
AS a format string, so the program's own braces were read as placeholders, and
no Koru program could emit a JSON line at all (630_006 pins it).

The zero-of-N was available the whole time and costs seconds to compute:
**1716 print messages in the corpus and not one carries a literal brace.**
Every one is prose addressed to a human, because every one was written to
demonstrate something to a human. A compiler author printing "added 3 rows" has
no reason to type a brace, ever.

So the sharpening is about *which* surfaces a foreign harness reaches:

- **The edges are the least-tested part of a language and the only part every
  foreign harness touches.** Argument grammar, machine-readable output, exit
  discipline — a corpus needs none of them, because it supplies its own inputs
  and reads its own outputs through a diff.
- **"Point the workload at the compiler" is not enough — ship it under the
  harness's own contract.** Re-spelling the hot loop in a scratch file would
  have found nothing here; the break lives only on the path from the program to
  the results file, which is the one part a scratch file gets to skip.
