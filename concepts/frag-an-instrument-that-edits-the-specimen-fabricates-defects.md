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
