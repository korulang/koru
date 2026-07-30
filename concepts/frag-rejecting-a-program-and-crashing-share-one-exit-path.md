---
type: belief
id: frag-rejecting-a-program-and-crashing-share-one-exit-path
provenance: Lars asking why he still sees Zig traces after the diagnostics sweep, 2026-07-30, on koru-examples/human-doodle/doodle.k; pinned as 510_118
ts: 2026-07-30
---

# Rejecting a program and crashing share one exit path, so a good diagnostic still ends in a crash report (belief)

The diagnostics sweep made refusals *speak Koru* — the sentence, and the channel
it travels on. It did not touch how the process **stops**. A rejected program and
a broken compiler leave through the same door, and Zig renders that door as a
crash.

`src/main.zig:930-938` emits into the generated `backend.zig`:

```zig
if (result.is_error) {
    __koru_std.debug.print("❌ Compiler coordination error: {s}\n", .{e});
    return error.CompilerCoordinationFailed;
}
```

The generated `main` calls it with `try`, so the error escapes `main` and Zig's
runtime prints `error: CompilerCoordinationFailed` plus an error-return trace
naming `backend.zig` — a file the author never opened. By then the real diagnostic
has already been printed, back in `compiler.kz:2864`. **The trace is not a
fallback for a missing message. It is the control flow becoming visible.**

That distinction matters for the fix. A fallback would mean "no diagnostic existed,
so something generic stood in" — the [[frag-no-fallbacks]] shape. This is the
opposite: the diagnostic was correct and complete, and the exit mechanism talked
over it.

## One mistake, four renderings

Measured on the doodle, in order:

1. `error[KORU030]: Resource 'response' obligation <tainted!> was not discharged.
   Call: validate-response` with `--> doodle.k:10:0` and a caret. **Correct** —
   names the resource, the obligation, the remedy, the position.
2. `❌ Compiler coordination error: Auto-discharge failed (multiple disposal
   options or no disposal event)` — vaguer, no location, and it **contradicts**
   (1), which names exactly one disposer. The "or" is not sloppy wording: one
   `error.ValidationFailed` value covers six distinct inserter failure paths
   (`compiler.kz:2877`), so the summary cannot say which fired.
3. The Zig error-return trace through generated files.
4. A `──── diagnostics (1) ────` block re-printing (1) with the location stripped.

Exactly one of the four is the diagnostic. The other three are the compiler
narrating its own plumbing, and the vaguest of them is the one that reads most
like a verdict.

## The double-report was known and accepted

`compiler.kz:2860-2864` documents it in place: the inserter's failure paths
"return without printing", and the two that print for themselves "double up,
exactly as they already did against the hand-formatted print this replaces." So
the duplication was inherited deliberately during the sweep rather than
introduced. Worth knowing before treating it as a regression — it is a deferred
decision, not a slip.

## What the result type is missing

`is_error` is one boolean carrying two meanings: *I refused the author's program*
and *I broke*. Nothing downstream can tell them apart, which is why the loud
rendering is applied to both. Suppressing the trace unconditionally would trade
this bug for its mirror — a genuine internal failure exiting quietly, which is
strictly worse, because a compiler crash reported as a rejection sends the author
hunting their own correct code.

The cheap discriminator available today: **a refusal is a failure that already told
the author something.** If the reporter delivered at least one diagnostic, exit
non-zero and quietly; if it delivered none, the loud trace is the right output and
should stay. That reads the existing state rather than adding a field, though a
kind on the result would be the honest version.

## Closing it is cheap — nothing depends on the leak

Measured 2026-07-30: zero tests assert on `CompilerCoordinationFailed`. The
category tokens in `EXPECT` (`BACKEND_RUNTIME_ERROR` and siblings, 36 tests) are
*skipped as informational* by `regression_lib.sh:191` — the real assertions are
`MUST_ERROR` plus `CONTAINS`/`NOT_CONTAINS`. The single test naming the summary
line, `430_001_user_coordinator`, asserts a **user-supplied** coordinator message
and stays green provided the print survives and only the exit path changes.

So the trace has been load-bearing for nothing. It persisted because it is
downstream of every diagnostic anyone was improving, and because a leak that
appears *after* a correct error reads as cosmetic.

## Open

- Whether (2) should exist at all once (1) is good. Its content is a summary of a
  six-way error value and its wording contradicts the specific diagnostic in at
  least this case. Options: drop it when the reporter has already spoken, or split
  `error.ValidationFailed` so each inserter path carries its own sentence. The
  second is more work and is the one that would make the summary true.
- Whether (4)'s location-stripped re-print should be dropped or should instead be
  the *only* rendering, with (1) suppressed. One of the two is redundant; which
  one survives depends on whether the trailing block is meant as a summary for
  multi-error runs.
- `430_001` pins that a user coordinator's message reaches the user through this
  same print. Any change to (2) has to keep that path — a user-authored
  coordination error is a real message, not plumbing.
