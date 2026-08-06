// The World in Koru — entry 9, negative twin of 849.
// Doorway: the double-counted ack. In Raft a peer's matchIndex is a map entry,
// so re-delivery is idempotent by construction; in ZAB the ack set is a Set
// (`SyncedLearnerTracker.addAck`, and `containsQuorum(Set<Long>)` — the type is
// the defence). TigerBeetle, which uses a counter rather than a set, has to
// defend explicitly: `assert(!prepare.ok_quorum_received)` plus a helper named
// `count_message_and_receive_quorum_exactly_once` (replica.zig:2318-2319).
//
// Three systems, three different mechanisms, one bug being warded off: counting
// one agreement twice and calling it two.
//
// Here the ack is consumed by counting it, so the second count has nothing left
// to consume. No set, no flag, no helper with "exactly once" in its name.
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

peer.matched(id: 1, index: 7): a1 |> tally.count(ack: a1, from: 1) |> tally.count(ack: a1, from: 1)

quorum.check()
| reached idx |> commit.advance(upto: idx)
    | advanced |> std/io:print.ln("commit -> {{ raft.commit:d }} on {{ raft.counted:d }} acks of 5")
    | stale |> std/io:print.ln("stale")
| short |> std/io:print.ln("no quorum on {{ raft.counted:d }} acks")
