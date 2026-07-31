---
type: belief
id: frag-a-declaration-and-its-body-stay-separate-lines
provenance: raised and dropped by Lars 2026-07-31, in the same sitting that ruled auto-proc synthesis out — "a couple of times a month I am tempted"
ts: 2026-07-31
---

# A tor's declaration and its body stay on separate lines (belief — a rejected spelling, recorded so it stops coming back)

Having just ruled that a phantom-only transition must be **spelled** rather than
synthesized (`350_002`), the obvious next thought is that the spelling could at
least be shorter. Two forms were put up:

```koru
~pub tor transition { r: *Resource<!state_a> } -> *Resource<state_b!> -> r

pub tor unlock { name: string<!held> } =
   std/io:print.ln("unlock {{ name:s }}")
```

Both are appealing, and the appeal is real enough to recur — Lars: *"a couple of
times a month I am tempted."* The second arrow is not even a new overload; the
two-line form already uses `->` for the return **type** on the declaration and
the return **value** on the body line. Fusing them deletes only the repeated tor
name.

**Ruled 2026-07-31: dropped.**

## The reason, and it is not aesthetic

A fused form has to work for **branches**, and there is no clean way to spell it.
A tor with terminal arms carries its outputs as a block:

```koru
~tor check { value: i32 }
| positive i32
| zero
| negative i32
```

There is no position after that where a single fused body could go, and inventing
one means a *second* syntax for the same idea — one shape for bare returns, a
different shape for branches. That is not a simplification of the grammar, it is
an addition to it.

So the fused form buys a deleted name on one class of tor and costs a new
construct on the other. **A rule that covers half the surface is worse than the
repetition it removes.**

## Why this is worth writing down at all

It is a *rejected* spelling, so nothing in the corpus will ever show it — and a
tempting idea that leaves no trace is one that gets re-proposed forever, each
time costing the same conversation. The rejection has a reason that survives
re-derivation, so record the reason and the reason will do the refusing.

⚖️ Note the shape of the argument, because it is the same one that settled
`350_002` an hour earlier and it generalises: **a construct that works for the
easy case and needs an invention for the hard one has not earned its place.**
There, synthesis worked where field names matched and needed a guess where they
did not. Here, fusion works for `-> T` and needs a new syntax for branches. Both
times the tell was that the second case could not be handled by the same idea.

## Open

- The repetition being removed — the tor's name on the body line — is genuinely
  redundant, and that is why the temptation recurs. If a future form covers
  branches naturally *without* a second construct, the objection recorded here
  is answered rather than reasserted; this belief is about the forms that were
  actually put up, not about the goal.
