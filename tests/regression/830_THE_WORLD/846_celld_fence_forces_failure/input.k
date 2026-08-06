// The World in Koru — entry 8, part three.
// Doorway: celld's node self-fence. (github.com/denoland/celld, Rust.)
//
// A celld node holds its authority as a lease in the bucket — `nodes/<node>.json`
// with an `expires_ms`, default TTL 10s, renewed every ttl/3, with a fence timer
// armed at ttl+1ms (`logic/lib.rs:1838-1844`). Miss the renewal and the node
// fences itself: `Effect::Halt { code: 3, reason: NodeLeaseExpired }`, and the
// process exits 3.
//
// The interesting part is what `fence()` does on the way out, and its comment
// says it exactly (`logic/lib.rs:3838-3843`):
//
//     Any write still waiting on the output gate loses its cell here, so it
//     must fail rather than be acknowledged — the fence and the fail are
//     atomic. A late DurableReached for a drained op is ignored.
//
// So it walks `gated_writes` and completes every one as `Err(NodeFenced)`. That
// loop is the whole invariant: NO WRITE IS ACKNOWLEDGED AFTER AUTHORITY IS LOST.
// It is correct because someone wrote it, remembered to write it, and will keep
// it correct as the code grows around it.
//
// Here it is not a loop. `gate.ack` BORROWS `<lease>` — acknowledging requires
// live authority — while `gate.fail` needs nothing. Surrender the lease and the
// ack becomes unreachable, so a pending response has exactly one way out left.
// The fence and the fail are atomic because there is no other shape the program
// can take. 847 is the proof: a valid durability proof in hand is not enough.
//
// LANGUAGE CORNER: renewal and fencing are the same resource read at two
// strengths. `node.renew { lease: string<lease> }` BORROWS — authority survives
// it, so the ack after it is legal. `node.fence { lease: string<!lease> }`
// CONSUMES. Nothing in the names carries that difference; the angle brackets do.
//
// And note the cost this slice pays, pinned in 848: adding `node.fence` gives
// `<!lease>` a SECOND consumer, which retires auto-discharge for leases
// entirely. In 838 a forgotten release was inserted for you. Here every control
// path must say how authority ended — which is celld's own
// `release_or_fence_node_lease`, named for the choice it has to make.
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

// msg-1 is served normally. msg-2 commits, and then the node loses its lease
// while that response is still gated — so the only remaining way out is a fail.
cas.claim(node: "node-a", guard: 0)
| applied l |> served(lease: l, data: "msg-1") |> cell.write(lease: l, data: "msg-2")
    | committed r2 |> node.fence(lease: l) |> gate.fail(r: r2, why: "node fenced")
    | not-resident |> std/io:print.ln("  not resident at commit epoch") |> cas.release(lease: l)
| rejected |> std/io:print.ln("  rejected")
