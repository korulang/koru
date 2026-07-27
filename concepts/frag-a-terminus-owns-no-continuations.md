---
type: belief
id: frag-a-terminus-owns-no-continuations
provenance: 210_189 — a dedented `! warn` arm following `bump(): v -> v` attached to the PRODUCE, not to `bump`; the loud failure was an undeclared identifier, the quiet one a dropped handler
ts: 2026-07-27
---

# A terminus owns no continuations, and attaching them there fails twice — once loudly, once silently (belief)

A produce (`-> v`) ends a chain. It is a value handed back, not a call, and it
has no branches, no effect arms, and nothing that could continue from it. The
parser nevertheless had one uniform rule for the handler lines that follow an
inline chain — *attach them to the deepest node* — and when a chain ends in a
same-line produce, the deepest node **is** the produce. So

    run = seed() |> bump(): v -> v
    ! warn m |> std/io:print.ln("warn {{ m:s }}")

parsed as `warn` handling the produce. It handles `bump`. The arms belong to the
last STEP, as siblings of the produce.

## The two failures are not equally visible

**Loud.** A produce that owns a continuation looks like a step that produces a
value, so the emitter stopped emitting it as a `return` and emitted the bare
constructor as an expression statement against a result variable nobody
declared. That reaches the author as `use of undeclared identifier 'v'` — their
own name, in a file they never opened.

**Quiet.** A produce owns no effect wiring, so the handler never reached the
splice resolver. `warn(...)` inside the proc body lowered to
`_ = ("fired")` — evaluate and discard, the lowering reserved for an
*unhandled optional* arm. The program compiled, ran, printed the right number,
and dropped the author's arm without a word.

Only the loud one got pinned, because only the loud one stops a build. The quiet
one is the reason the fix matters: it is indistinguishable, from the outside,
from an arm whose condition never fired.

## What follows

- **A structural misattachment produces a type error and a silent drop, and the
  type error is the lucky half.** When a fix is motivated by a compile failure,
  ask what ELSE the same wrong shape reaches — here, the handler wiring, which
  had no diagnostic to give.
- **Probe the dropped path, not just the pinned one.** The pin's program has
  `! warn` that never fires, so it could have gone green with the handler still
  unwired. Making the proc actually fire the arm is what separated "the bind is
  back" from "the handler is back".
- **`_ = (expr)` is the tell.** It is the sanctioned lowering for an unhandled
  optional effect arm. Seeing it where a handler was written means the wiring
  never found the handler — a shape question, not an emission question.

## Open

Two sibling attachment sites in `parser.zig` still walk to the deepest
continuation and hang the multi-line handlers there
(`parseContinuationInternal`, `parseBranchContinuation`). If a chain inside a
branch-handler body ends in a produce, the same misattachment is available. No
test reaches it today, and none was written — the corpus has no instance of that
spelling, which is exactly why 210_189's shape went unexamined for so long.
