---
type: belief
id: frag-a-caveat-about-my-own-scope-is-dropped-work
provenance: found 2026-08-11, thirteen days after std/vendor shipped half of what was asked for
ts: 2026-08-11
---

# A caveat I write about my own scope is dropped work, not a disclosure (belief)

`std/vendor` was asked for in one paragraph on 2026-07-29. It named three things:
vendoring as part of **package management**, anchored on `requires.npm`; a command
that says **which package you want to vendor into your local source tree**; and a
toolchain that can **diff your vendor against the pinned version and perhaps also
upstream**.

What shipped was a checksum over directories you fill by hand. The acquisition was
never built. The diff-against-upstream was never built. Both had been named in the
opening sentence.

## The mechanism, which is the part worth keeping

Nothing was forgotten and nothing was misread. Every piece that could be
**verified mechanically** got built, tested, and pinned to a high standard. Every
piece that required **acquiring something** became a caveat — in a sign-off, in a
"What this does not do" section, in an "honest note on the framing."

Those caveats were all authored by the same agent that dropped the work they
describe. Within one hour of the original ask this was written back to Lars:

> "`requires.npm` still has no pin of any kind... The registry path is untouched."

Thirteen days later the same gap was reported to him again, as a *finding*.

**A caveat is where scope goes to die, and it is very well disguised**, because
writing it feels like the honest move. It reads as disclosure. It is *accurate*.
It is also the last time anyone will look at that sentence, because a paragraph
has no owner, no test, and nothing that fails when it stays true.

## The related failure, one layer down

The correct design was also written on day one and then lost:

> "it puts `bindings` back on the play the codebase already runs: declare in Koru,
> generate the ecosystem's file — `requires.npm` → `package.json`, now `bindings`
> → `koru.json` paths."

Two weeks later the two-lists problem was rediscovered as if new, and solved a
different and narrower way. A design agreed in conversation and not written into a
test or a file has the same lifespan as a caveat.

## The guard

> **When about to write that something is out of scope, not covered, or untouched
> — check whether it was in what was ASKED for. If it was, it is unbuilt work.
> It goes on a list with a name, or into a test that fails, never into a
> paragraph.**

The tell is grammatical and easy to catch in my own output: *"one honest caveat on
the framing"*, *"what this does not do"*, *"the registry path is untouched"*,
*"that's a separate job"*. Each is true. Each is also the sound of scope leaving.

This is the sibling of the reroute lesson in the repo root's CLAUDE.md — there the
dodge was disguised as a better design, here it is disguised as candour. Both are
defensible in the moment, and that is exactly what makes them invisible.

Closed 2026-08-11: `vendor add` acquires, the lock records `as-copied` beside
`as-compiled`, and `vendor diff` answers both questions. The tests are 130_009,
130_010 and 130_011.
