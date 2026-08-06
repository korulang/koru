# The quorum commit rule — a second witness, and where linearity stops

Entry 8 (`838`–`848`) ported three invariants from celld and drew two
conclusions. Both carried the same weakness, written into the fragments at the
time: **one system, read closely, that advertised its pure decision core.**

This entry goes looking for the second witness on purpose, and picks the
invariant that three other systems independently nominated as the one a linear
type should *not* be able to hold.

| entry | marker | what it pins |
|---|---|---|
| `849_raft_quorum_commit` | `MUST_RUN` | acks as linear resources; the `> half` threshold and the commit advance stay runtime |
| `850_raft_double_counted_ack` | `MUST_ERROR` | `KORU030` Use-after-discharge — one agreement cannot be counted twice |
| `851_raft_identity_is_not_linearity` | `MUST_RUN` | **passes, and prints the wrong answer** — the boundary |

## The survey

Four implementations of the same job, read at source rather than from their docs:

| system | is there a pure decision core? | did it say so? |
|---|---|---|
| celld (Rust) | **ENFORCED** — separate crate, zero dependencies, `"no async, I/O, clocks, randomness, locks"` | **yes** |
| TigerBeetle (Zig) | CONVENTIONAL — pure state machine, but determinism comes from *injectable I/O*; consensus is fused with Storage/Journal | no |
| hashicorp/raft (Go) | NOT ENFORCED — one pure cell (`commitment.go:88-105`) inside a channel-driven loop with inline disk reads | no |
| ZooKeeper (Java) | **ABSENT** — commit and epoch decisions run inside socket-owning threads | no |

The architectural claim did not survive: only celld is built that way, and celld
is the one that advertised it. ZooKeeper is mature, correct, and in production
having never needed a decision core at all.

What *did* survive, four for four: the correctness-bearing **computation** is
pure everywhere. `containsQuorum` is `return (ackSet.size() > half);`
(`QuorumMaj.java:140`). `recalculate()` is a median with no I/O. TigerBeetle's
state machine imports no clock. Whether the codebase *separates* that
computation is house style; that it *is* pure appears not to be.

## What linearity reaches

An ack is a resource — minted once by `peer.matched`, consumed once by
`tally.count`. Counting the same one twice is refused (`850`).

That is not a small thing. Double-counting an agreement is the classic quorum
bug, and each surveyed system spends something to ward it off: Raft keys
`matchIndex` by `ServerID`, ZAB holds a `Set<Long>` and types `containsQuorum`
to take one, and TigerBeetle — which uses a plain counter — needs an explicit
`assert(!prepare.ok_quorum_received)` plus a helper named
`count_message_and_receive_quorum_exactly_once` (`replica.zig:2318-2319`).

## Where it stops — `851`

`851` passes, and what it prints is wrong. That is the finding.

```
  counted ack from peer 1 at index 7
  counted ack from peer 2 at index 7
  counted ack from peer 2 at index 7
commit -> 7 on 3 acks of 5
```

Peer 2 agreed twice. Two acks minted for the same peer are two genuinely
distinct resources, each consumed exactly once, entirely legally — and a
majority is declared on the word of two voters.

The peer id is passed straight into `tally.count`. The compiler holds the
identity at the call site and can do nothing with it, because **an obligation is
a statement about a value's lifetime and never about its equality to another
value.** Linearity counts tokens; quorums count identities. Every real
implementation defends this with a *set*, and a set is not something a linear
type can stand in for.

## The boundary, stated once

Across four slices and two families of system, the line has landed in the same
place every time:

- **Types hold provenance and at-most-once.** This value came from the minting
  path; it was used the number of times its type allows.
- **Runtime holds identity, comparison, and counting.** Is this the same peer.
  Is this position greater. Are there more than half.

`> half` is arithmetic. `> commitIndex` is arithmetic. Neither is expressible as
an obligation, and neither should be faked as one.

## Reproducing

```sh
./run_regression.sh raft      # all three
./run_regression.sh celld     # entry 8, eleven entries
```

Sources read at: hashicorp/raft `8064883`, ZooKeeper `53a78e36`, TigerBeetle
`97c7a8e`, celld `553ae73f`.
