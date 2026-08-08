---
type: belief
id: frag-an-inliner-must-resolve-the-callee-the-way-the-call-would
provenance: An effect-bearing event at the top of a flow takes an inline lowering that pastes findDefaultZigProc's body into the caller. It never consulted the variant registry, so a `build:variants` selection was ignored and the DEFAULT body ran. Found 2026-08-08 putting orisha's pump on Unikraft; fixed, pinned as 370_012
ts: 2026-08-08
---

# An inliner must resolve the callee exactly the way the call would

Inlining is supposed to be invisible: same answer, no frame. That promise rests
entirely on the inliner and the call agreeing about **which body** is the
callee — and the moment anything other than the name selects that body, the two
have to ask the same question or they diverge.

koruc lowers an effect-bearing event at the head of a flow by splicing the proc
body into the caller instead of calling it. The splice asked
`findDefaultZigProc`, full stop. The call path asks `getVariant(canonical)` first
and only falls back to the default. So a `~proc run|unikraft` selected through
`std/build:variants` was chosen correctly at every call site and **silently
ignored at every spliced one** — the default body ran.

**Nothing failed.** That is the whole character of this defect. No missing
symbol, no type error, no diagnostic: the program ran, and it ran the wrong
platform's code. It only became visible on a target where the default body could
not compile at all, and even then the error named `kqueue` — a call the program
does not make and the author never wrote — pointing at libc from inside a
freestanding build. An optimization that picks the wrong callee does not report a
wrong callee; it reports whatever the wrong callee happens to break.

Two things generalize.

**A fast path is a second implementation of a decision, and decisions drift.**
The `inv.variant != null` guard was already there — an *explicit* variant at the
call site correctly bailed out of the splice. Someone had seen this exact
question and answered it for the spelling that existed then. The registry
arrived later and nobody revisited the guard, so the fast path stayed right about
one of the two ways a variant can be chosen. **A guard that enumerates cases ages
badly**; it should ask the question, not list the answers.

**When in doubt, decline the optimization rather than reimplement the
decision.** The fix is not "splice the selected variant" — it is "when a variant
is selected, don't splice." The call path already knows how to dispatch and, since
`e0a366c4`, how to thread effect arms into a variant handler. Giving the work back
to the one path that already resolves correctly is smaller than teaching a second
path to resolve, and it cannot drift again.

Same family as
[[frag-a-name-mangling-dispatcher-assumes-a-parity-nobody-maintains]] (a call
site assuming what the emitter did not maintain) and
[[frag-a-check-and-its-satisfier-must-enumerate-the-same-set]] (a checker and its
satisfier enumerating different sets). Three defects in one day where **two code
paths held the same question and only one of them was kept current.**
