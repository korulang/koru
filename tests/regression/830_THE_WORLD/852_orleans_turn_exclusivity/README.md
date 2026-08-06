# Orleans' turn model — and the third wall, which is the same wall

| entry | marker | what it pins |
|---|---|---|
| `852_orleans_turn_exclusivity` | `MUST_RUN` | a non-reentrant call *borrows* the turn; a reentrant one *consumes* it and re-grants |
| `853_orleans_state_without_a_turn` | `MUST_ERROR` | `KORU030` no tracked phantom state — grain state cannot be touched outside a turn |
| `854_orleans_state_after_the_turn_ends` | `MUST_ERROR` | `KORU030` Use-after-discharge — the turn *is* the permission |
| `855_orleans_stale_read_survives_the_interleave` | `MUST_RUN` | **passes, and a bump vanishes** |

## Why reentrancy, and not the obvious thing

Orleans is the ancestor of the Durable Objects model that entry 8 ported, so
the tempting target is its single-activation guarantee. **That port would be a
lie.** Orleans' exclusivity is best-effort, and its own source says so:

- `GrainDirectoryHandoffManager.cs:162` — *"Record the applications which lost
  the registration race (duplicate activations)."* Line 174: *"Destroy any
  duplicate activations."*
- `LocalGrainDirectoryPartition.cs:85` — *"Grain is supposed to be in single
  activation mode, but we have two activations!!"*
- `GrainDirectoryPartition.Interface.cs:170` — a new activation replaces an
  existing one whenever `IsSiloDead(existing)`, and deadness comes from
  best-effort health probes.

celld's equivalent is an S3 compare-and-swap with the epoch in the object
prefix, which makes duplicate ownership logically impossible. Orleans'
`MembershipVersion` is an advisory view stamp, not a fence. **A compile-time
guarantee on top of a best-effort runtime property is a lie with a checkmark on
it.**

Reentrancy is the honest target: `MayInvokeRequest`
(`Catalog/ActivationData.cs:1187`) is the one genuinely pure predicate in that
runtime — no I/O, no timers — it is already marker-shaped (`[Reentrant]`,
`[AlwaysInterleave]`, `[MayInterleave]`), and it is within-silo and
within-activation, which is a scope a type system actually reaches.

## What the turn buys

Borrow versus consume is the spelling of *does this suspension keep the turn?*
A non-reentrant call borrows `<exclusive>`; a reentrant one consumes it and
mints a fresh turn. Nothing in the names carries that difference — in Orleans
it is a class attribute whose consequences live entirely in the developer's
memory.

`852` is the safe shape: `state.bump` is read-modify-write **atomic within the
turn**, so no value escapes and an interleave between two bumps is harmless.
That is exactly the advice every Orleans guide gives about reentrant grains,
reached here from the type side rather than from a style rule.

## Where it stops — `855`

```
  await other-grain — REENTRANT; another turn bumped to 1
  count := 0
  turn resumed ends
the other turn's bump is gone; count is 0
```

A value read before the suspension is written after it. The other turn's
increment is gone. `<fresh>` is a claim about the binding `x`; `<exclusive>` is
a claim about the binding `t1`; Koru cannot say the first dies when the second
is discharged.

**A near-miss worth recording.** The first draft of `855` used the natural
`state.write(v: x + 1)` and it *was* refused — for a reason with nothing to do
with staleness. Arithmetic strips the obligation, so `x + 1` carries no
`<fresh!>`, and the same refusal fires with no interleave in the flow at all.
Shipping it would have published an incidental type error as a safety property.
The control that caught it was one run: the same write, no interleave.

That trap is also the second finding — this encoding can only express *write
back exactly what you read*, which is why `852`'s atomic bump is the shape that
works.

## The third wall is the same wall

| entry | the type holds | the wall | the relation it needed |
|---|---|---|---|
| 8 · celld | a durability proof exists | `durable >= position` | this proof ≥ that position |
| 9 · Raft | an ack is consumed once | a false quorum from one peer | this token's peer ≠ that token's peer |
| 10 · Orleans | the interleave is explicit | a stale read survives it | this value's validity depends on that binding's liveness |

An obligation is a **unary** claim about one binding's lifetime. Every wall so
far is a **relation between two things**. Belief:
`concepts/frag-an-obligation-is-unary-every-boundary-is-relational.md`.

## Reproducing

```sh
./run_regression.sh orleans   # all four
./run_regression.sh celld     # entry 8
./run_regression.sh raft      # entry 9
```

Orleans read at commit `c5d13879`.
