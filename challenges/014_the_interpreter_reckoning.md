---
challenge: interpreter-reckoning
kind: survey
status: standing
yields: a decision about the runtime/interpreter family, backed by a read of what actually exists — not code
family: runtime
---

*Walker context — the recurrence that earned this frame. The runtime/interpreter
family was **parked on 2026-05-15** with an explicit instruction: do not
investigate, do not propose fixes, do not touch the stdlib code. The unparking
signal was defined as Lars saying so — "not a stale-feeling memory three weeks
from now."*

*It has now been ten weeks. It is roughly **6,600 lines across seven surfaces**.
It renders **44 tests that report nothing**. And Lars's words on 2026-07-31 were:
"We ALSO have the interpreter, I am a little unsure what we should do there."*

*That is not an unpark. It is a request for the survey that would let someone
decide. **This frame produces a decision brief, not a fix.***

---

## The brief (sealed — you are the contestant)

Say what the runtime/interpreter family **is**, what **works**, what it is
**for**, and what the **three or four real options** are. Ground every claim in
a file, a line, or a test that ran.

**Write no fix.** Change no `koru_std/*.kz` in this family. The park stands until
Lars lifts it, and the point of this frame is to give him what he needs to
decide — not to pre-empt the decision by shipping.

## ⛔ Read this before anything else

`project_runtime_interpreter_parked` in memory is binding, and it carries a
**correction you must not violate**:

> The "interpreter is 5x slower than Python / retired" framing is **OUTDATED**.
> The runtime interpreter has since been made a lot faster than the old budgeted
> one; its bespoke parser and its own runtime are **deliberate speed choices,
> not a trap.** Never repeat the slower-than-Python or "stays retired" framing.

If your survey reaches for that framing, you have reproduced a known error. The
correction is from Lars, 2026-07-03.

## What exists — the map to verify, not to trust

Measured 2026-07-31; re-derive rather than quoting this table.

| surface | lines | last touched |
|---|---|---|
| `koru_std/interpreter.kz` | 2447 | 2026-07-25 |
| `koru_std/runtime.kz` | 1750 | 2026-07-25 |
| `src/interpreter.zig` | 1250 | 2026-06-10 |
| `koru_std/eval.kz` | 454 | 2026-07-24 |
| `koru_std/runtime_control.kz` | 344 | 2026-07-24 |
| `koru_std/inter.kz` | 178 | 2026-07-24 |
| `koru_std/bridge.kz` | 147 | 2026-07-24 |

Note what those dates say: this family was **touched five weeks after it was
parked**, including a real fix (`d7e2eae9`, "440_RESOURCE_BRIDGE goes green") and
a real feature (`2c4c6f39`, "reject `~` in interpreter source"). The park was
about the *bug family*, not the code. Establish that boundary precisely — it
changes what "parked" currently means.

Their own headers claim four distinct things, and whether those are one system or
four is the first question:

- **`interpreter.kz`** — runtime evaluation of Koru source, using *the same
  parser as the compiler*, walking the AST and dispatching to registered events.
- **`runtime.kz`** — a scoped registry: `register(scope:)`, `collect-scopes`,
  `get-scope`. A capability boundary, not an evaluator.
- **`eval.kz`** — an expression evaluator whose header makes a pointed claim:
  *"Expressions are parsed at parse-time (not strings!)"*.
- **`inter.kz`** — something else entirely: `koruc myapp.kz --inter`, a
  **comptime-only** interactive TUI for stepping through the compiler's own
  pipeline. It is in this family by filename and possibly by nothing else.

## The board's dark half

```
430_RUNTIME               37 todo   all: "ASPIRATIONAL: the runtime interpreter is deferred pending a rewrite."
410_BUDGETED_INTERPRETER   7 todo   all: "ASPIRATIONAL: the budgeted interpreter is deferred pending a rewrite."
440_RESOURCE_BRIDGE        2 green  ← the exception, and see challenge 015
430_COORDINATION           6 green, 2 red, 3 todo
```

Two questions the todos raise on their face:

1. **"Pending a rewrite" — is a rewrite actually the plan?** Forty-four tests
   assert it in unison. If that phrase was copied forward rather than decided,
   the board is stating a plan nobody currently holds. Find out which.
2. **Is the budgeted interpreter (410) the same system as the runtime one (430),
   or its predecessor?** The parked memory's correction implies **two**
   interpreters, one superseding the other. If 410 pins a retired design, those
   seven tests are not deferred — they are dead, and should say so.

Two known parked specifics to check against today's code:
`430_037_interpreter_field_types` (`v.num` reads 0 instead of the propagated
`int_val`) and `430_047_runtime_run_parse_error` (`run` accepts `"ping()"` with no
leading `~`, returning `result` instead of `parse_error`). That second one
carries the live design question: **is interpreter source implicit-Koru, or does
it require `~`?** Note `2c4c6f39` already *rejected* `~` in interpreter source —
so either the question was answered and 430_047 is stale, or the answer went the
other way and the test is now wrong. **That contradiction is the single
highest-value thing in this survey. Resolve it.**

## The pre-garden — are these 44 tests worth keeping?

This is most of the frame's value. For a representative sample (not all 44 —
enough to characterise), establish:

- **Would it even be a good test if the feature worked?** A todo is a promise. A
  bad test kept as a todo is a promise to build the wrong thing.
- **Does it pin behaviour, or an implementation?** Tests that pin
  `HandlePool`-shaped internals cannot survive a rewrite, and should not be held
  up as reasons to rewrite.
- **How many are `.kz` with raw-Zig bodies?** The two green 440 tests reach
  straight into `@import("root").koru_std.koru_interpreter.HandlePool`. If most of
  the family is Zig wearing a `.kz` extension, the "rewrite" may really be **a
  Koru surface over a working Zig core** — a much smaller job than it looks.
  See `baton_library_boundary_zig_leaks_commission`.
- **What fraction would a rewrite actually have to satisfy?** Give the number.

## What "done" looks like

A decision brief Lars can read in ten minutes, containing:

1. **What this is** — one paragraph per surface, and whether they are one system.
2. **What works today**, demonstrated by tests that ran, not by reading.
3. **The 430_047 contradiction, resolved.**
4. **What it is for** — the honest answer, which may be "two unrelated things
   sharing a directory."
5. **Three or four options**, each with what it costs and what it buys. Include
   *delete some of it* as a real option, and *unpark nothing* as a real option.
6. **A recommendation**, stated plainly.
7. **The 44 tests re-dispositioned**: which are live promises, which pin a retired
   design, which are bad tests. That much is landable regardless of the ruling —
   see challenge `016`.

## Failure modes

- **Shipping a fix.** The park stands. This frame ends at a brief.
- **Repeating the slower-than-Python framing.** Corrected by Lars; see above.
- **Treating `inter.kz` as part of the interpreter** without checking. It is
  `~[comptime]` and it drives the *compiler's* pipeline.
- **A survey with no numbers.** "Substantial" is not a measurement.
- **Answering the implicit-Koru question yourself.** Spellings are Lars's. Bring
  it with the evidence.
