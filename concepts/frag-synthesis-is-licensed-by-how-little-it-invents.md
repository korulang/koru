---
type: belief
id: frag-synthesis-is-licensed-by-how-little-it-invents
provenance: two rulings hours apart on 2026-07-31 — mid-chain auto-discharge (built) and auto-proc for bare returns (declined) — which look like the same generosity and are opposite in kind
ts: 2026-07-31
---

# What the compiler may synthesize is decided by how much information the synthesis invents, not by how convenient it is (belief)

Two questions arrived on the same day and both read as *"the compiler can
obviously see what you meant — should it just do it?"*

**Mid-chain auto-discharge** (`330_120`). `make(): h |> bump(h)` — `bump` hands
back an obligation nobody binds, one void disposer in scope, and the compiler's
refusal *named the disposer it declined to call*. **Ruled: synthesize.**

**Auto-proc for a bare return** (`350_002`).
`transition { r: *Resource<!state_a> } -> *Resource<state_b!>` with no body —
one input, matching base type, only one possible implementation. **Ruled: do
not synthesize.**

Convenience does not separate these; both save the author a line or a name.
Difficulty does not either; both are small. What separates them is what the
compiler has to make up.

## The line

**Auto-discharge synthesizes a NAME.** The value exists. Its type is known. The
disposer is known and the compiler proves it by printing the disposer's name in
the refusal. A name is the one thing missing, and a name is bookkeeping the
compiler already holds — it invents nothing. Requiring the author to supply it
made the feature's own definition read *"settles obligations you did not write
down, provided you wrote down a name for them."*

**Auto-proc for a bare return synthesizes an IMPLEMENTATION.** Nothing in the
program says identity is correct. The compiler would be *asserting* it, and
under phantoms an assertion about behaviour is a **guarantee**.

The test case that settles it: `validate { t: *Token<!raw> } -> *Token<checked!>`
has the identical signature shape — consumes one phantom, issues another, same
base type. Synthesize identity there and you hand back a token marked `checked!`
that nothing checked. **A phantom claiming a property no code established is the
guarantee lying**, which is the worst failure available in this language.

## Evidence, not inference, is what licenses a synthesis

The rule the exemption *encodes* is the right one: synthesize only when input and
output fields match by **name and type**, because the author naming the output
after the input **is** the evidence that passthrough was meant. That is an author
signal, read — not a shape the compiler inferred.

A bare return has no field name. So that evidence cannot exist, and the rule
would degrade to "one input whose base type equals the return's" — a coincidence
of types rather than a statement of intent. `350_004` marks the other edge: an
**uncalled** tor needs no proc at all, because nothing depends on what it would
have done.

### ⛔ CORRECTION, same day — the exemption is DEAD CODE, and I cited it wrongly

I first wrote this section citing `350_001` as the green proof that the exemption
works. **It is not.** Measured:

- `350_001`'s `EXPECT` holds the bare line `42` — one of the census's
  unrecognized-`EXPECT` files — with no `MUST_RUN` and no `expected.txt`. Its
  `passthrough` is never called and the `verify` it names does not exist. It is
  green because **nothing is checked**, under `350_004`'s uncalled-tor rule.
- The exemption at `shape_checker.zig:829-841` fires only when `return_type ==
  null`, exactly one terminal branch, and that branch **carries payload fields**.
  `PARSE003` now refuses precisely that shape — *"single continuation branch
  carrying a payload is a one-variant tag union — declare the single output as a
  bare return instead"*. The single-return migration made its only trigger
  unspellable.

So the "existing feature" this belief was contrasted against **fires never**, and
the whole `350_AUTO_PROC` category exercises the two *narrowings* (`350_002`
spelled, `350_004` uncalled) and not the feature.

**The conclusion is unchanged and arguably stronger.** Extending synthesis to
bare returns was never "extending a working feature" — it would be reviving a
dead one in its weakest form, the form with no name-match evidence at all. And
the load-bearing argument never depended on the exemption: `validate { t:
*Token<!raw> } -> *Token<checked!>` stands on its own.

What this does add is a live question: the dead exemption should either be
deleted or given a reachable trigger, and nothing currently tells us which.

## Why "it's only one line" is not an argument for removing the line

`transition -> r` is short. It is not empty. It is where the author says
*identity is what I mean here* — a true and reasonable claim for a phantom
transition, and one that would look **obviously wrong to a reader** in the
validator case, where `validate -> t` visibly validates nothing.

Ceremony is a line that carries no information. This line carries the whole
decision. **Brevity is not emptiness**, and the cost of deleting a short line is
measured in what it was asserting, not in its length.

## Open

- The rule is stated over *information invented*, which is judgement, not a
  predicate. There is no mechanical test for "does this synthesis assert
  something." The two worked cases are the anchor; a third that does not sort
  cleanly would be the interesting one.
- `330_123` records a live consequence of the auto-discharge half: under
  `--auto-discharge=disable` the mid-chain shape is now walled nowhere, because
  the normalize-only pass never reached it. Synthesis that is correct by default
  still owes a wall in the mode that opts out of it.
