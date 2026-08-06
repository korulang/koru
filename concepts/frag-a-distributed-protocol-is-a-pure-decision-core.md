---
type: belief
id: frag-a-distributed-protocol-is-a-pure-decision-core
provenance: created 2026-08-06 from denoland/celld; CORRECTED the same day after surveying hashicorp/raft, Apache ZooKeeper and TigerBeetle, which refuted the architectural half of it
ts: 2026-08-06
---

# The correctness-bearing computations of a distributed protocol are pure — but the protocol is NOT a pure decision core, and I had no business saying it was (belief)

**CORRECTED 2026-08-06.** The first version of this fragment was titled *"A
distributed protocol is a pure decision core; the sockets are the boring half."*
That sentence is false, it was never true, and I asserted it about a **domain**
on evidence from **one system's packaging**. What follows keeps the part that
survived four witnesses and repudiates the part that did not.

## The claim that survives

Koru has no working threads, no sockets, no file writes, no clock. That reads
like a disqualification from distributed-systems work, and it is not one,
because the correctness-bearing *computations* of these protocols are pure —
in every system surveyed, without exception:

- **celld** — the whole protocol in one crate declaring *"no async, I/O, clocks,
  randomness, locks, or dependencies."*
- **hashicorp/raft** — `commitment.recalculate()` (`commitment.go:88-105`), the
  median-of-matchIndexes that decides the committed prefix: no I/O, no clock,
  no randomness.
- **ZooKeeper** — `QuorumMaj.containsQuorum` is literally
  `return (ackSet.size() > half);` (`QuorumMaj.java:140`); `isMoreRecentThan`,
  `totalOrderPredicate` and `makeZxid` are equally pure.
- **TigerBeetle** — `src/state_machine.zig` imports no io, no clock, no rand;
  the timestamp arrives as data in the replicated header.

Four out of four. **The convergence-critical decision is always a pure function
of data the protocol already has.** That is the operative fact for Koru, and it
is stronger now than when it rested on celld alone.

## The claim that was wrong

That the *protocol* is a pure core, and the shell a replaceable box around it.
Only celld is built that way, and celld is the one system that **advertised** it
— the exact selection effect this fragment's original "where this is weak"
section warned about, then fell into anyway.

| system | seam | advertised? |
|---|---|---|
| celld | ENFORCED — separate crate, zero dependencies | **yes** |
| TigerBeetle | CONVENTIONAL — pure state machine, but determinism comes from *injectable I/O*, and consensus in `replica.zig` is fused with Storage/Journal | no |
| hashicorp/raft | NOT ENFORCED — one pure cell inside a channel-driven event loop with inline disk reads | no |
| ZooKeeper | ABSENT — commit and epoch decisions execute inside socket-owning threads | no |

ZooKeeper settles it. It is mature, correct, in production everywhere, and it
**never needed a decision core to be right**. A property the domain does not
require is not a property of the domain.

TigerBeetle sharpens it differently: it reaches determinism by making I/O and
time *injectable* rather than by separating a core. That is a second viable
architecture for the same goal, so even "separate it if you want determinism" is
too strong.

## What this cost me, and the transferable lesson

The original said *"a clock is shell, like a socket is shell"* and *"nothing
inside the function asks what time it is."* TigerBeetle's
`expire_pending_transfers` asks what time it is and decides against the answer
(`state_machine.zig:446`, driven from `replica.zig:3936`). It stays correct only
because the wall-clock reading is committed into the replicated log **before**
it may decide. So the honest rule is not *"a timer is never a decision"* but
**"a timer's reading must become replicated data before it may decide."**

The lesson under all of it: **I generalized an architecture from a system that
told me about its architecture.** A project that advertises a property has
selected itself for that property, and is therefore the weakest possible witness
for it. The three unadvertised systems were worth more than the one that
volunteered — and two of them contradicted me.

## Where this could still be wrong

- All four are consensus-or-lease systems. The purity of the deciding
  computation may be a property of *replication* protocols specifically rather
  than of distributed systems at large. A gossip, CRDT, or scheduling system
  might not have a single deciding function at all.
- "Pure computation exists inside it" is a much weaker claim than the one it
  replaces, and weaker claims are easier to survive. The sharp, falsifiable form
  worth holding is: *for any replication protocol, the decision that determines
  convergence can be written as a function of already-received data.* A
  counter-example — a protocol whose convergence decision genuinely requires
  reading a clock or a socket mid-decision — would correct this again.
- It says nothing about deployment. A protocol core that cannot be run against a
  real bucket is a proof, not a product.
