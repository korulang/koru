// The World in Koru — entry 9. A SECOND WITNESS, and a deliberate boundary test.
// Doorway: the quorum commit rule, as four different systems spell it.
//
//   hashicorp/raft   commitment.go:98    quorumMatchIndex := matched[(len(matched)-1)/2]
//   ZooKeeper        QuorumMaj.java:140  return (ackSet.size() > half);
//   TigerBeetle      replica.zig:2318    assert(count == threshold);
//   celld            — has no quorum at all; its coordinator is a bucket.
//
// WHY THIS ENTRY EXISTS. Entry 8 ported three invariants from celld and drew two
// conclusions from them. Both carried the same weakness, written into the
// fragments at the time: one system, read closely, that ADVERTISED its pure
// decision core. So this entry goes looking for a second witness on purpose,
// and picks the invariant all three other systems independently nominated as
// the one a linear type should NOT be able to hold.
//
// WHAT LINEARITY REACHES. An ack is a resource: minted once by `peer.matched`,
// consumed once by `tally.count`. Counting the same ack twice is refused — 850.
// That is not a small thing; double-counting an agreement is the classic quorum
// bug, and TigerBeetle spends a dedicated flag on it
// (`assert(!prepare.ok_quorum_received)`, replica.zig:2319).
//
// WHAT IT DOES NOT REACH, and this is the point of 851: linearity counts
// TOKENS, not IDENTITIES. Two acks minted for the same peer are two distinct
// resources, each legitimately consumed once, and they form a quorum of three
// out of two real voters. The compiler cannot see it. The peer id is passed
// right into `tally.count` and changes nothing, because an identity is data and
// linearity is about tokens.
//
// So the boundary lands exactly where entry 8 said it did, now from a different
// family of systems: TYPES HOLD PROVENANCE AND AT-MOST-ONCE; RUNTIME HOLDS THE
// COMPARISONS AND THE COUNTS. `> half` is arithmetic. `> commit` is arithmetic.
// Neither is expressible as an obligation, and neither should be faked as one.
import std/io
import std/store

// Five voters, so a majority is three. `half` is ZooKeeper's precomputed
// `half`; `counted` and `best` are the tally; `commit` is Raft's commitIndex.
std/store:new(raft, capacity: 1) { counted: 0[i64], best: 0[i64], commit: 0[i64], half: 2[i64] }

// One peer's durable agreement at an index — Raft's matchIndex, ZAB's ack.
// Minted by the replication path; it is the only source of <ack!>.
pub tor peer.matched { id: i64, index: i64 } -> i64<ack!>
peer.matched -> index

// Counting CONSUMES the ack. `from` is carried only so the trace can show it —
// note that the identity is right there in the call and changes nothing.
pub tor tally.count { ack: i64<!ack>, from: i64 }
tally.count = std/store:stored { raft.counted: raft.counted + 1, raft.best: ack }
    |> std/io:print.ln("  counted ack from peer {{ from:d }} at index {{ ack:d }}")

// ZooKeeper: `return (ackSet.size() > half);` — arithmetic, so it stays runtime.
pub tor quorum.check {}
| reached i64
| short
quorum.check = if(raft.counted > raft.half)
| then => reached raft.best
| else => short

// Raft: the commit index only advances. Also arithmetic.
pub tor commit.advance { upto: i64 }
| advanced
| stale
commit.advance = if(upto > raft.commit)
| then |> std/store:stored { raft.commit: upto } => advanced
| else => stale

peer.matched(id: 1, index: 7): a1 |> tally.count(ack: a1, from: 1)
peer.matched(id: 2, index: 7): a2 |> tally.count(ack: a2, from: 2)
peer.matched(id: 3, index: 7): a3 |> tally.count(ack: a3, from: 3)

quorum.check()
| reached idx |> commit.advance(upto: idx)
    | advanced |> std/io:print.ln("commit -> {{ raft.commit:d }} on {{ raft.counted:d }} acks of 5")
    | stale |> std/io:print.ln("stale")
| short |> std/io:print.ln("no quorum on {{ raft.counted:d }} acks")
