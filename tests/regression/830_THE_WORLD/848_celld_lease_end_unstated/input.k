// The World in Koru — entry 8 part three, negative twin two of 846 — and the
// COST of this slice rather than a benefit of it.
// Doorway: celld's `release_or_fence_node_lease`. The name is the finding. Once
// a node's authority can end two ways — handed back cleanly, or taken away —
// there is no longer a default, and celld's shell has to pick one at every exit
// it has.
//
// 838 got the opposite deal: `<!lease>` had exactly ONE consumer, so
// auto-discharge inserted the release and a forgotten lease was impossible.
// Adding `node.fence` in 846 gives it a second, and that RETIRES the insertion
// for every lease in the program. This test is the arm that forgot: the
// `not-resident` path never says how authority ended, and it no longer gets an
// answer for free.
//
// Recording it as a test because it is a real consequence of a design move that
// looks purely additive. A second discharger is not just another API — it
// removes the safety of forgetting from every existing call site, and that
// blast radius should be a known cost, not a surprise. This one was found by
// walking into it while writing 846.
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
| applied l |> served(lease: l, data: "msg-1") |> cell.write(lease: l, data: "msg-2")
    | committed r2 |> node.fence(lease: l) |> gate.fail(r: r2, why: "node fenced")
    | not-resident |> std/io:print.ln("  not resident at commit epoch")
| rejected |> std/io:print.ln("  rejected")
