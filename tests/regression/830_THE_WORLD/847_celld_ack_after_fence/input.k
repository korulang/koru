// The World in Koru — entry 8 part three, negative twin one of 846.
// Doorway: celld's late durability completion. A `DurableReached` can arrive
// for a write whose gate the fence already drained — the replicator finished
// its upload, the proof is genuine, and the position really does cover the
// write. celld still must not acknowledge it, because the node no longer owns
// the cell and can no longer promise to serve what it acked. `durable_reached`
// therefore opens by dropping completions for gates that are gone
// (`logic/lib.rs:3700`), and `fence()` is careful to make draining and failing
// atomic so no window exists between them.
//
// This is the case where a real proof is not enough, and it is the one a
// hand-written guard is most likely to miss: everything about the write is
// valid except the authority to answer for it.
//
// Here the proof IS genuine — `replica.sync` minted it, and it covers the
// position. The ack is refused anyway, because `gate.ack` borrows the lease and
// the lease was surrendered on the line before.
import std/io
import std/store

std/store:new(own, capacity: 1) { epoch: 0[i64], etag: 0[i64] }
std/store:new(st, capacity: 1) { pos: 0[i64], synced: 0[i64] }

pub tor cas.claim { node: string, guard: i64 }
| applied string<lease!>
| rejected
cas.claim = if(guard == own.etag)
| then |> std/store:stored { own.etag: own.etag + 1, own.epoch: own.epoch + 1 } => applied node
| else => rejected

// The two ways authority can end. celld's shell calls exactly one function for
// this and names it `release_or_fence_node_lease`.
pub tor cas.release { lease: string<!lease> }
cas.release = std/io:print.ln("  release {{ lease:s }} — clean handoff")

pub tor node.fence { lease: string<!lease> }
node.fence = std/io:print.ln("  SELF-FENCE {{ lease:s }} — lease not renewed within TTL")

// Renewal borrows. Authority survives it, which is the whole point of a renewal.
pub tor node.renew { lease: string<lease> }
node.renew = std/io:print.ln("  renew {{ lease:s }}")

pub tor cell.write { lease: string<lease>, data: string }
| committed string<pending!>
| not-resident
cell.write = if(own.epoch > 0)
| then |> std/store:stored { st.pos: st.pos + 1 } => committed data
| else => not-resident

pub tor replica.sync { lease: string<lease>, upto: i64 }
| reached i64<durable!>
| behind
replica.sync = if(upto <= st.pos)
| then |> std/store:stored { st.synced: upto } => reached upto
| else => behind

// ACKNOWLEDGING NOW REQUIRES LIVE AUTHORITY. Failing does not.
pub tor gate.ack { r: string<!pending>, proof: i64<!durable>, lease: string<lease> }
gate.ack = std/io:print.ln("  ack  {{ r:s }} — durable through {{ proof:d }}")

pub tor gate.fail { r: string<!pending>, why: string }
gate.fail = std/io:print.ln("  fail {{ r:s }} — {{ why:s }}")

// A request served under live, renewed authority.
pub tor served { lease: string<lease>, data: string }
served = cell.write(lease, data)
| committed r |> node.renew(lease) |> replica.sync(lease, upto: st.pos)
    | reached p |> gate.ack(r, proof: p, lease)
    | behind |> gate.fail(r, why: "durability unproven")
| not-resident |> std/io:print.ln("  not resident at commit epoch")


cas.claim(node: "node-a", guard: 0)
| applied l |> cell.write(lease: l, data: "msg-1")
    | committed r2 |> replica.sync(lease: l, upto: st.pos)
        | reached p2 |> node.fence(lease: l) |> gate.ack(r: r2, proof: p2, lease: l)
        | behind |> gate.fail(r: r2, why: "behind") |> cas.release(lease: l)
    | not-resident |> std/io:print.ln("  not resident") |> cas.release(lease: l)
| rejected |> std/io:print.ln("  rejected")
