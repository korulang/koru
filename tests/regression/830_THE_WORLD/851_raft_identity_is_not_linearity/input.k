// The World in Koru — entry 9, THE BOUNDARY. This test passes, and what it
// prints is WRONG. That is the finding, and it is the reason the entry exists.
//
// Doorway: a quorum forged from one voter. Every real consensus implementation
// defends the peer SET, not the ack COUNT — ZooKeeper's `containsQuorum` takes a
// `Set<Long>` of server ids (QuorumMaj.java:140) and Raft keys matchIndex by
// ServerID, so a peer that acks twice occupies one slot either way. The identity
// is what is deduplicated, and the data structure is the whole defence.
//
// Linear obligations cannot do that. `<ack!>` makes each token consumable once,
// which stops 850 — but two tokens minted for the SAME peer are two genuinely
// distinct resources, each consumed exactly once, entirely legally. Below, peers
// 1 and 2 agree, peer 2 agrees a second time, and the tally reads three of five.
// A majority is declared and the commit index advances on the word of two
// voters.
//
// Read the trace: it says `counted ack from peer 2` twice. The id is passed
// straight into `tally.count`. The compiler has the identity in its hand at the
// call site and can do nothing with it, because an obligation is a statement
// about a value's LIFETIME and never about its EQUALITY to another value.
//
// The honest conclusion: linearity is not a substitute for a set. It reaches
// provenance ("this came from the minting path") and cardinality-per-token
// ("counted at most once"), and stops. Deduplicating identities, comparing
// magnitudes, and counting to a threshold all stay runtime work — which is
// where all four surveyed systems in fact do them.
//
// This is pinned as MUST_RUN rather than MUST_ERROR deliberately. There is no
// diagnostic to pin; the absence of one IS the result, and a test that records
// the wrong answer is the only way to keep that visible.
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
peer.matched(id: 2, index: 7): a2b |> tally.count(ack: a2b, from: 2)

quorum.check()
| reached idx |> commit.advance(upto: idx)
    | advanced |> std/io:print.ln("commit -> {{ raft.commit:d }} on {{ raft.counted:d }} acks of 5")
    | stale |> std/io:print.ln("stale")
| short |> std/io:print.ln("no quorum on {{ raft.counted:d }} acks")
