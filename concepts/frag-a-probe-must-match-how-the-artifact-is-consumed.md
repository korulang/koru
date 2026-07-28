---
type: belief
id: frag-a-probe-must-match-how-the-artifact-is-consumed
provenance: a 200-char terminal probe certified FileWriter.print as fixed; the same code shredded 109 tests because the harness captures stderr to a file, where File.writer's positional writes overwrite instead of append
ts: 2026-07-28
---

# A probe that does not match how the artifact is consumed is not evidence about the artifact (belief)

`FileWriter.print` was changed to stream through `File.writer()` rather than
format into a fixed buffer. The probe: print 200 characters through an 8-byte
buffer, watch them all arrive. They did. The change was reported as SHOWN.

It then destroyed 109 tests, because `File.writer` tracks its own offset and
issues **positional** writes. A fresh writer per call means every call restarts
at offset 0. Against a terminal that is invisible — positional writes to a tty
degrade to appends, so the probe could not have failed. Against a seekable file
each diagnostic overwrites the last, which is exactly how the test harness
captures stderr.

The probe was real, the output was real, and it certified nothing, because
**stdout-to-a-tty and stdout-to-a-file are different machines**. The claim was
about the compiler's error output; the measurement was taken in the one
configuration where the defect cannot appear.

## What follows

- **Name the consumer before designing the probe.** Not "does this print" but
  "does this print *the way the thing that reads it* will read it." Redirected,
  piped, captured, non-tty — if the real consumer differs from the probe's, the
  probe is answering a different question.
- **The tier is MEASURED (narrow), and the configuration belongs inside the
  sentence.** "200 chars through an 8-byte buffer, to a terminal" would have
  exposed the gap at the moment of writing it. "SHOWN" hid it. The status stamp
  works only when the configuration is stated, not assumed to match.
- **Environment-sensitive I/O is the sharp case, and it is broader than
  writers.** Buffering, line-vs-block flushing, colour/ANSI, `isatty` branches,
  and positional-vs-streaming offsets all change behaviour based on what the fd
  is attached to. Any of them can make a green hand-probe and a red suite
  simultaneously honest.
- **A suite result that contradicts a hand probe means the probe was wrong about
  its own conditions**, not that the suite is flaky. Resolve it by re-probing in
  the suite's configuration, never by re-running the probe that already agreed
  with you.

## Open

Whether `koruc` should own ONE writer for user-facing diagnostics rather than
constructing one per call. A single long-lived writer removes the offset-reset
foot-gun structurally instead of by remembering which constructor to call —
the same shape of argument as the compilation owning ONE `ErrorReporter`. Not
attempted here; the twin cliff at `koru_std/compiler.kz:2121` builds its own
writer too, so there is more than one consumer to reconcile.
