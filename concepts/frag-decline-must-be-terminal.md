---
type: belief
id: frag-decline-must-be-terminal
provenance: three silent subflow-body miscompilations diagnosed together 2026-07-27 (pins 210_177 / 210_178 / 210_179; 210_169 flipped green by the same emitter fix)
ts: 2026-07-27
---

# When the primary consumer declines a node, a secondary consumer must not quietly absorb it (belief)

Two passes, in two different halves of the compiler, showed the same shape on the
same night: something the pass that *owns* a construct declined to take was not
refused — it was picked up further downstream by machinery that had no idea what
it was looking at, and the author's meaning vanished with no diagnostic anywhere.

**Parser.** A subflow body is claimed by `parseContinuations`, which stops at the
first line that is not a `|` / `|>` / `!` continuation. Koru sequences a body with
`|>`; listing statements is not a body form, so an indented line under a subflow
definition is exactly such a stop. The line was then absorbed twice over, once per
file form: a `.k` synthesizes a leading `~` on any top-level-looking line, so the
line became a **top-level flow that ran at program start** — the subflow was never
called and its lines printed anyway; a `.kz` requires `~` for Koru, so the line
was **passed to the host verbatim** and surfaced much later as a Zig parse error
against generated code. Neither absorber was wrong locally. Both were catastrophic
because the first consumer's decline carried no signal.

**Emitter.** A subflow body's continuations are walked by whichever branch of the
subflow emitter matches the head. `emitFlow` routes every top-level inline body
through one shared helper that walks all of them; the subflow branch for a
transform-headed chain hand-rolled a *second* walk that lowered only the node kind
it happened to know (`branch_constructor`). Every other step of the chain — plain
calls included — fell off the end of that loop. The program still compiled, still
ran, still exited 0, and printed less than it was written to print.

The unifying rule is not "parse better" or "emit more kinds". It is:

> **A decline must be terminal.** If the machinery that owns a construct will not
> take a piece of it, nothing downstream may treat that piece as ordinary input.
> Either the owner takes it or the toolchain refuses it by name.

## Why this class is so quiet

Both failure modes produce a program that *works* in every sense a suite can see
without an exact expected output: exit 0, no diagnostic, no crash. The parser
version even runs the author's code — just at the wrong time, in the wrong scope.
That is why the pins for it assert a **count** or an **exact transcript**
(210_177, 220_021) rather than mere success: nothing weaker separates "the chain
ran" from "the chain stopped after its head".

## The tell to look for

A second walk over a list the codebase already has one walker for. When a
`for (…continuations…)` loop appears inside a branch of an emitter and lowers a
subset of node kinds inline, that loop is the bug — not because its cases are
wrong, but because its `else` is silence. The fix is never to add the missing
case; it is to delete the walk and call the shared one, which is what makes the
next unknown kind a compile error instead of a dropped statement.

## Relation to the top-level-position family

[[frag-transform-continuation-position]] collects passes that special-case
"top-level / flow-root" position and mis-handle the nested case. This is the same
asymmetry seen from the other side: there, the nested path *lost* a treatment the
root path had; here, the non-top-level path *re-implemented* it and re-implemented
it incompletely. Same root cause — two code paths for one construct — and the same
remedy, one route for both.

## Open

Whether listing statements in a subflow body should stay refused or become legal
sequencing is Lars's ruling and is NOT settled here. This belief only says the
line may not be silently rehomed; the wall it currently gets (KORU010, located,
naming both meaningful spellings) is the conservative reading and can be replaced
by a semantics without touching anything above.
