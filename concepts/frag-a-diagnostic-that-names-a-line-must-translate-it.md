---
type: belief
id: frag-a-diagnostic-that-names-a-line-must-translate-it
provenance: KORU106's "already bound at line N" printed a parser coordinate one line off from its own caret, because the caret goes through ErrorReporter.classifyLine and interpolated prose does not
ts: 2026-07-27
---

# A diagnostic that names a second line in its prose must translate that line the same way its caret is translated (belief)

`koruc` parses a source with an auto-injected bootstrap prelude prepended, so
every line number inside the compiler is a **parser coordinate**, offset from the
line the author sees by the prelude's height. `ErrorReporter.classifyLine`
converts one to the other, and it runs on exactly one thing: the location an
error is reported *at*.

A diagnostic that names a second position — "already bound at line N", "the
first handler is at line M" — interpolates that number into the message string,
which never passes through the reporter at all. The result is a sentence whose
prose and whose caret disagree by a constant, in a compiler where both look
equally authoritative.

The failure is quiet in the worst way: it is a *plausible* line number. It
points at real source, one line off, and reads as if it were checked.

## What follows

- **Any line number that reaches the user through message text goes through
  `ErrorReporter.userLine` first.** The location argument is handled for you;
  everything else is not.
- **A single-error probe cannot show this.** The bug only appears once a
  diagnostic names two positions, and only when the two disagree. Reading the
  caret and believing the prose is the natural mistake, because the caret is
  right.
- **The same trap is open to any future multi-site diagnostic** — duplicate
  handlers, conflicting declarations, a second obligation. There is nothing
  structural stopping it; the discipline is the wall.

## Open

Whether the message API should take positions rather than pre-formatted numbers,
so translation cannot be skipped. That would make the rule mechanical instead of
remembered, at the cost of a wider signature on every reporter entry point. Not
attempted here — one consumer is not a design pressure.
