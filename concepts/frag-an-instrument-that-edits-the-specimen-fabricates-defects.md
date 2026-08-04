---
type: belief
id: frag-an-instrument-that-edits-the-specimen-fabricates-defects
provenance: 2026-08-04 — six "flow position" compiler bugs found in one sitting, all fabricated. The probe files were authored through an IPython cell, which rewrites any line beginning with `!` even inside a triple-quoted string, so every `! each` / `! sweep` branch line reached the compiler as `__omp_shell("...")`
ts: 2026-08-04
---

# An instrument that edits the specimen fabricates defects, and they look exactly like real ones (belief)

Koru's branch lines start with `!`. IPython's input transformer rewrites any
line starting with `!` into a shell call, and it does so on the RAW CELL TEXT,
before Python parses it — so it fires inside triple-quoted strings too. Every
`.k` probe authored that way arrived at the compiler with its branch lines
replaced by `__omp_shell("each k |> ...")`.

The compiler then reported, correctly, that the branch was missing. Six times,
in six shapes, with six different diagnostics that composed into a coherent and
completely false story: that a top-level `for` "reaches across a blank line and
consumes the next construct's branch". A regression test was written pinning
that behaviour, with a header confidently explaining the mechanism. The
behaviour does not exist.

## Why it survived scrutiny

Every check I would normally trust said the finding was solid, and each one was
answering a question adjacent to the real one:

- **It reproduced.** Deterministically, six for six. But re-running a corrupted
  instrument reproduces the corruption, not the defect.
- **The diagnostics were specific and plausible.** `KORU022 branch 'each' must
  be handled` is exactly what a real version of this bug would emit.
- **The error MOVED when I changed the following statement**, which read as
  strong evidence of an attachment bug. It was: different mangled files fail
  differently.
- **A green corpus test used the shape**, so I concluded the shape was green *by
  accident of its composition* rather than concluding my probe was wrong. The
  corpus was the control and I explained it away instead of believing it.

What finally broke it was the one thing that looks at the specimen rather than
the result: the diagnostic quoted the offending source line back, and the line
it quoted was not the line I wrote.

## What follows

- **A diagnostic that quotes your source is the cheapest instrument check there
  is, and it is nearly free.** Read the quoted line before reading the message.
  If the tool does not echo the input, `cat` the file that was actually
  compiled — not the buffer you believe you wrote.
- **Author test inputs through a writer that does not transform**, and treat any
  cell/REPL/heredoc layer as a transformer until shown otherwise. The failure is
  silent by construction: a transformer that announced itself would not be one.
- **When a green corpus artifact contradicts your probe, the probe is the
  suspect.** This is the same instinct as the truth hierarchy in AGENTS.md —
  runnable tests outrank prose — extended one step: they also outrank a
  measurement I just took. I had the control and argued with it.
- **A found bug should be reproduced OUT OF BAND before it is written down** —
  a different authoring path, ideally a different tool. Six identical-path
  reproductions are one observation, not six.

## The sibling, and how this one differs

`frag-a-probe-must-match-how-the-artifact-is-consumed` is the same family: a
probe whose CONTEXT differed from the real consumer (tty versus captured file)
certified a change that then shredded 109 tests. Both are instruments that were
not neutral.

The mechanisms are opposite ends of the same pipe, and so are the mitigations.
There, the probe read a real artifact in the wrong environment — fix by naming
the consumer. Here, the probe never contained the artifact at all — fix by
verifying the input on disk. A probe can be wrong about what it FED IN as
easily as about what it READ OUT, and the input side is the quieter of the two
because there is no output to look surprising.

## Open

- Whether anything else in this repo's workflow rewrites `.k` source in transit.
  `!` at line start is the obvious collision because Koru's branch syntax uses
  it, but `%`, `?`, and a leading `$` are magic in the same layer and Koru uses
  none of them at line start today. That is luck, not design, and a future
  syntax choice could collide the same way.
- Whether the six-shape "finding" would have survived into a commit if the
  program had been slightly different — the false pin PASSED the harness, since
  the harness reads the file rather than the cell. A pin that passes while
  asserting a bug is a contradiction the harness cannot report, and nothing in
  the tooling would have caught it.


## It happened again the same day, and the belief being written down did not stop it

The first Open bullet above asks whether anything else in the workflow rewrites
`.k` source in transit. Partial answer, from the inside, roughly twelve hours
later: **the same transformer, through a path the section above does not
describe.**

The original instance authored the probe *as* the cell — the `.k` text was the
cell body. This one wrote files programmatically:
`pathlib.Path(dst).write_text(SRC)`, with `SRC` a triple-quoted literal several
statements above the write. Every `! each` line still arrived on disk as
`__omp_shell("each _ |> ...")`.

So the collision is not a property of *how the probe is invoked*. It fires on any
Koru text that **transits** a python cell, including text being handled purely as
data on its way to a file. There is no formulation of "author it carefully" that
survives this, because at the moment of writing, the string is not being executed
and does not feel like code at all.

And the honest part: **this belief existed, in this corpus, when it happened.** It
was authored that morning, from the identical mechanism, and it names the
identical mitigation. It did not fire. That is the same structural claim
`frag-a-suspicion-in-a-handoff-becomes-the-next-readers-starting-point` makes
about itself — a belief recorded in the corpus does not self-apply at the moment
it is needed — and two independent arrivals at it in one day is the argument for
mechanical mitigations over written ones.

## The check that actually worked was cheaper than the one recommended above

The section above nominates the diagnostic's quoted source line as the cheapest
instrument check. It was not what broke this one — the refusal came back as a
bare `KORU022` with no quoted line, so that check was unavailable.

Two things did the work, and both are cheaper:

- **A green corpus artifact, compiled in the same scratch directory, in the same
  minute.** Three known-green tests copied in and run before any verdict was
  trusted. They passed, which localised the fault to the probe rather than the
  tree or the compiler. This is the control the original instance *had* and
  argued with; running it FIRST, as the opening move rather than as a rebuttal,
  is what makes it decisive instead of ignorable.
- **Printing the bytes back in the same breath as writing them.** Not as a
  separate act of diligence — as part of the compile command, so it cannot be
  skipped when hurried. `sed -n '/^import/,$p' probe.k` beside the diagnostic put
  `__omp_shell(...)` on screen next to the error it caused.

The general form: **a probe should emit its own input alongside its own verdict.**
An instrument that reports only conclusions cannot be audited by the person
reading it, and that person is always the one most invested in the conclusion.