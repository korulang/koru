---
type: belief
id: frag-trap-the-sink-not-the-emitter-sites
provenance: 2026-08-08 — a session tagged every literal `_ = &result;` and every dynamic `_ = &` write in `src/`, rebuilt, and watched none of them fire; the real site writes `"_ = &"`, then a computed name, then `";\n"` in three separate calls, and a trap on the emitter's buffer tail found it on the first run
ts: 2026-08-08
---

# To find who emitted a string, trap the sink — the source sites are the wrong search space (belief)

A generated file had a line nobody could account for. The hunt that failed was
the obvious one and it was thorough: find every place in the compiler that
writes that exact text, mark each one, rebuild, see which mark appears. All the
marks were placed. None of them fired. The honest conclusion drawn from that —
"the text is assembled some other way" — was correct, and it still left the
search with nowhere to go, because *some other way* is not a thing you can grep
for.

The reason the search could not succeed is structural, not a matter of care. An
emitter builds a line out of fragments: a fixed prefix, a name computed from the
AST, a terminator. **No single call site ever contains the finished string**, so
no search over the sources — literal, regex, or otherwise — can name the site.
You are looking for a sentence in a place that only ever holds words.

The move that works is to stop searching the producers and instrument the one
place every fragment must pass through. Every emitted byte in this compiler goes
through one `write` on the output buffer. Add four lines there: after the append,
compare the buffer's tail against the string you are hunting, and on a match dump
a stack trace. The trace names the exact call site, its caller, and the pass that
drove it. First run, no guessing, and it works identically whether the line was
one write or twenty.

Three properties make this general rather than a trick:

- **It is keyed on the artifact, not the code.** The input is the bad line as it
  appears in the output file — the only thing you actually know. You never have
  to guess how it was spelled in the source.
- **It survives assembly.** Fragments, formatting helpers, indentation writers,
  string builders spliced in from elsewhere: all of them land in the same buffer,
  so all of them are caught by the same trap.
- **It is honest about absence.** If the trap never fires, the text genuinely did
  not come through that sink, and *that* is a real finding that points somewhere
  else — a spliced host body, a template, a second emitter. A silent set of
  source markers tells you nothing of the kind, because "I marked the wrong
  sites" and "it isn't written here" look the same.

The precondition is a single chokepoint. Where one exists, use it. Where one does
not, the first useful work is usually to make one, because a compiler with many
independent output paths cannot be instrumented at all and every future hunt of
this shape pays the same cost.

One trap detail worth keeping, because getting it wrong reads as "the trap
doesn't work" and sends you back to the wrong search. Compare against the tail of
the buffer **with trailing whitespace skipped**, and only when the write being
appended was itself non-blank. A site that writes the text with its newline
attached will not match a tail comparison that expects the text flush to the end,
and an indentation writer emitting single spaces will otherwise re-fire the trap
forever after the first match.

Standing next to `frag-calibrate-a-check-by-sabotage`: a trap that has never
fired is not yet evidence of anything. Before trusting a silent trap, make it
fire once on a string you know is emitted.
