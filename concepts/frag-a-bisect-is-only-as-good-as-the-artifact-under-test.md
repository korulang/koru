---
type: belief
id: frag-a-bisect-is-only-as-good-as-the-artifact-under-test
provenance: 2026-08-08 — two stale-artifact errors in one session, one against an emitted file and one against the compiler binary
ts: 2026-08-08
---

# A bisect is only as good as the artifact under test being the one you edited (belief)

"Disable the pass and see whether the symptom persists" is a sound bisect and it
is how the store's preamble bug was found. The same move, hours later, returned
a confident wrong answer — that dead-strip was not what removed an uncalled
export — because the disable had never been compiled into the binary doing the
work.

The failure is not carelessness about rebuilding. It is that **knowing one half
of the rule is what hides the other half.** `koru_std/*.kz` needs no rebuild:
the stdlib is read at compile time, and a store or io change takes effect on the
next invocation. That is true, useful, and load-bearing all day. `src/*.zig` is
the opposite — it compiles INTO koruc — and the habit built by the first fact is
exactly what suppresses the question for the second.

Twice in one session, in two disguises:
- Conformance verified against an `output_emitted.js` whose compile had failed,
  so the check passed against the previous build.
- A pass disabled in `src/dead_strip.zig` and measured without `zig build`, so
  the measurement described a compiler that no longer existed.

Both times the artifact was present, recent, and plausible. Nothing about
reading the result suggests it is stale — that is the whole problem. A failed
compile leaves the last good output sitting there, and an un-rebuilt binary is
indistinguishable from a rebuilt one at the shell.

**The mechanical guard: compile and check in ONE step, never two.** `koruc … &&
grep …` fails loudly when the compile fails; `koruc …` on one line and `grep` on
the next reports on whatever happens to be on disk. Where the edit is to the
compiler rather than the program, the step is `zig build && koruc … && check`.

The second guard is cheaper and catches the class: **before believing a
surprising negative result, change the thing under test in a way that MUST be
visible** — a marker in a diagnostic string, a deliberate syntax error. If the
sabotage does not show up, the artifact is stale, and that is a two-second
question with a definitive answer.

Related: [[frag-a-partial-success-is-a-better-disguise-than-a-total-failure]] —
same session, same shape. Both are cases where the evidence was real and
described a different world than the one being reasoned about.
