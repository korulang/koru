---
type: belief
id: frag-a-red-tests-nothing-past-its-first-wall
provenance: challenge 012 diagnosed all 24 obligation/control-flow reds before fixing any; 19 of them died on surface walls (PARSE003/PARSE005/KORU022) added after they were written and never reached the obligation machinery they pin
ts: 2026-07-31
---

# A red tests nothing past its first wall (belief)

A failing test is only evidence about the thing it pins if the program gets far
enough to exercise that thing. The moment an earlier wall refuses the program —
a parse rule, a spelling ban, a coverage check — everything downstream of the
wall is untested, and the red stops meaning what its name says.

The board cannot show the difference. "24 obligation reds" read as "obligations
are broken where control flow bends" — the largest red mass on the board,
elevated to a standing challenge on that reading. Diagnosis showed most of them
last passed together in one snapshot window and died on *later surface rulings*:
the single-return migration outlawed their fixtures' lone-payload branches,
mandatory punning refused their call sites, 510_109 outlawed the inline bind
their probes were spelled with. The obligation semantics they pin were in
several cases *fixed years of commits ago* (330_091's disable-path borrow) or
correct all along (335_044's taint boundary) — provable only by re-spelling the
program and watching the pinned refusal fire.

## The consequence for reading a board

Failure *stage* is the tell, and it is cheap: a `frontend` failure on a test
that pins a backend semantic is a category error by construction — the pin
lives in a stage the program never reached. Cluster reds by the wall they
actually hit before clustering them by what their names claim, or the map
inherits the names' fiction.

## The consequence for migrations

A migration that outlaws a spelling converts every unmigrated test into this
state silently: still red, still counted, testing nothing. The burn-down that
accompanies a surface ruling is not cosmetic cleanup — it is what keeps the
suite's reds meaning anything. An unmigrated MUST_ERROR is the worst case: it
"passes" its expectation of failure for the wrong reason, or flips to
must-error-passed noise, and either way the diagnostic it pins goes unguarded.

## The private-harness variant

The wall is not always a compiler ruling. 430_020 ("parked green→red
regression, interpreter if e2e" — carried in the cluster TODO as the one real
regression in the family) reproduced its red through a 150-line private
`runInterpreter` in the test body, reaching into parser internals. Respelled
through the public surface (`std/runtime:run` on the same if-source), both
directions dispatched correctly on the first try — the machinery was green all
along; what broke at the blamed commit was the test's own plumbing. A red that
pins internals through a private harness is evidence about the harness first
and the system second, and it can park as "regression" for weeks on the
strength of that confusion.

Related: [[frag-a-failure-that-looks-like-success-is-unfalsifiable]] — the
mirror case, where a green means nothing; here a red means nothing.

## The trap when you go to FIX one: two faults can stack, and repairing the visible one restores the invisible one

`335_046` was red for two independent reasons at once, and the outer one hid the
inner one so completely that the obvious repair would have made things worse.

- **Outer, visible:** its program declared `~tor make {} | ok *Handle<owned!>` — a
  single continuation branch carrying a payload — which a later ruling refuses
  outright (`PARSE003`, one-variant tag union: declare it as a bare return). So it
  died at the frontend, never reaching the checker its `EXPECT` named. Classic
  instance of this belief: red, counted, testing nothing.
- **Inner, invisible:** its PREMISE was also false. It asserted that a borrowed
  obligation followed by a pipeline continuation leaks and "MUST be rejected". It
  is not rejected because it does not leak — auto-discharge inserts the disposal,
  and the emitted program names it on the line the note called a leak.

**The dangerous repair is the competent one.** Respelling to a bare return is a
two-line, obviously-correct migration that any careful reader makes first. It
clears the frontend wall — and then the test reaches its checker, the checker
correctly does nothing, and the `MUST_ERROR` + `CONTAINS was not discharged`
expectation fails. The tempting next move is to "fix the checker": file a compiler
bug against a compiler that is behaving correctly. That is exactly the path that
produced a false defect report and a commissioned bugfix elsewhere the same day.

So the migration rule needs a second clause. Getting a rotted red past its first
wall is not enough:

- **Re-derive the premise before repairing the spelling.** The spelling rotted
  because the language moved; the premise may have been wrong from the start, and
  nothing about the spelling fix tests it. Ask what the program SHOULD do under
  current semantics, not what its note expected.
- **A stale red's note is the least trustworthy thing in the directory**, because
  it was written when the shape was legal and has gone unexecuted ever since. Its
  file:line citations and its controls may describe a compiler that no longer
  exists.
- **The tell that you are in a two-fault case:** the repair is small and certain,
  and the test still fails afterwards. Treat that second failure as a question
  about the premise, never as the next bug.

`335_046` is now green, respelled and flipped `MUST_ERROR` -> `MUST_RUN`, pinning
what actually happens: a borrowed obligation whose state has exactly one
unattended disposer is auto-discharged, and a continuation after the borrow does
not change that. Kept rather than deleted, and renamed from `..._drops_obligation`
to `..._auto_discharges`, because a directory name is an assertion too.
