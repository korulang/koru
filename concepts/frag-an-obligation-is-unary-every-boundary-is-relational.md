---
type: belief
id: frag-an-obligation-is-unary-every-boundary-is-relational
provenance: three ports in one day — celld's lease and gate (838-848), Raft's quorum (849-851), Orleans' reentrancy (852-855) — each of which hit a wall, and the walls turned out to be the same wall
ts: 2026-08-06
---

# An obligation is a unary claim about one binding's lifetime; every boundary found so far is a RELATION between two things (belief)

Three distributed-systems invariants were ported to phantom obligations, from
two unrelated families of system. All three worked, all three stopped, and the
stopping points looked like three different limitations:

- **celld's gate** — the type carries a durability proof, but not that the proof
  *covers position N*. `durable >= position` stayed runtime.
- **Raft's quorum** — the type makes an ack consumable once, but two acks minted
  for the *same peer* are two legal resources. A false quorum compiles
  (`830_THE_WORLD/851`).
- **Orleans' reentrancy** — the type makes the interleave point explicit, but a
  value read before the suspension is still valid after it. The lost update
  compiles (`830_THE_WORLD/855`).

They are one limitation. An obligation is a predicate over **one binding**: this
value was minted by that path, and it has been consumed this many times. Every
wall hit was a claim about **two things**:

| wall | the relation it needed |
|---|---|
| gate | this proof ≥ that position |
| quorum | this token's peer ≠ that token's peer |
| reentrancy | this value's validity depends on that binding's liveness |

**The durable claim: before trying to hold an invariant in a type, ask whether
it is about one value's lifetime or about a relationship between two values.
Only the first is reachable.** Ordering, magnitude, equality, and
liveness-dependence are all relations, and a per-binding phantom state cannot
express any of them.

## Why this is the useful form

Stated as three separate failures it reads as "the type system is not powerful
enough yet," which invites the wrong work — bolting on a comparison here, a
dedup there. Stated as one property it is a **design test you can apply before
writing anything**, and it predicts where the next port will stop without
running it.

It also says what to do instead, and the three ports agree on the answer:
**eliminate the relation by changing the shape.** Orleans' safe pattern
(`852`) is read-modify-write atomic inside the turn — no value escapes, so no
value can go stale, so the relation never arises. That is not a workaround; it
is the same advice the Orleans documentation gives, arrived at from the type
side.

## A near-miss worth keeping

The first draft of `855` "caught" the lost update, and the catch was fake.
Writing `state.write(v: x + 1)` IS refused — because arithmetic strips the
obligation, so `x + 1` carries no `<fresh!>` at all. The identical refusal fires
in a flow with no interleave in it. Publishing that would have presented an
incidental type error as a safety property, with a green test underneath it.

The general hazard: **when a wrong program is refused, confirm it is refused for
the reason you are about to claim.** The control is a right program that differs
only in the property under test — here, the same write with no interleave. It
took one run and it inverted the finding.

## Where this could be wrong

- Three data points, and two came from the same afternoon's momentum. A fourth
  port that stops on something genuinely unary would correct this.
- Koru has machinery I have not tried against these walls — field-granular
  obligation narrowing, and phantoms synthesised as derived names. If a derived
  phantom can encode "minted while `t1` was live," the reentrancy wall at least
  is reachable and this belief is too pessimistic.
- "Relational" may be doing too much work. Equality-of-identity and
  ordering-of-magnitude are different problems, and one may fall while the other
  does not. If dedup becomes expressible and comparison does not, this wants
  splitting.
