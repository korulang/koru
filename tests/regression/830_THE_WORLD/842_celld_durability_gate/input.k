// The World in Koru — entry 8, part two.
// Doorway: celld's output gate — the reason its Durable Objects claim RPO=0.
// (github.com/denoland/celld, Rust.)
//
// Over there, a handler that commits to SQLite does NOT get to answer. The
// commit emits `Event::Wrote { request, position }`, the core files a
// `GatedWrite` and emits `Effect::AwaitDurable`, and the response sits in
// `gated_writes` until the replicator proves a position in the bucket. Only
// then does `durable_reached` compare — and it acknowledges *only* when
// `durable >= gate.position` (`logic/lib.rs:3711`). A shorter proof, from a
// lagging or lying replicator, FAILS the write rather than acknowledging one
// the node could not actually restore. Acknowledgement and durability are made
// one act, so losing a node cannot lose an acked write.
//
// The discipline is: hold the response, and never let it out on your own
// judgement. That is a rule about a value's lifetime, which is what Koru's
// obligations are.
//
// Here `cell.write` mints `<pending!>` — an UNANSWERED RESPONSE — and the only
// consumers of `<!pending>` are `gate.ack` and `gate.fail`. `gate.ack`
// additionally consumes `<!durable>`, a proof minted only by `replica.sync`,
// so one proof covers one gated write exactly as one `await_durable` ticket
// does. An answer cannot be invented (843) and a request cannot be quietly
// dropped (844).
//
// LANGUAGE CORNER: the same mechanism, read by ARITY OF DISCHARGE. A lease has
// exactly one way back (`cas.release`), so auto-discharge inserts it and you
// cannot leak a lease — that is 838, and you can see it fire on the last line
// of this trace. A response has TWO ways out, so auto-discharge refuses to
// choose and the program must put every request's fate in writing. celld
// reaches the same place by hand: its fence explicitly drains every gated write
// to a FAILED response (`logic/lib.rs:3838`), because silently dropping and
// silently acking are both lies. Here neither can be the default.
import std/io
import std/store

// The owner record from 838, plus the cell's two positions. celld takes its
// commit position from SQLite's `total_changes`; `synced` is what the
// replicator has actually put in the bucket.
std/store:new(own, capacity: 1) { epoch: 0[i64], etag: 0[i64] }
std/store:new(st, capacity: 1) { pos: 0[i64], synced: 0[i64] }

pub tor cas.claim { node: string, guard: i64 }
| applied string<lease!>
| rejected
cas.claim = if(guard == own.etag)
| then |> std/store:stored { own.etag: own.etag + 1, own.epoch: own.epoch + 1 } => applied node
| else => rejected

pub tor cas.release { lease: string<!lease> }
cas.release = std/io:print.ln("  release {{ lease:s }}")

// A commit advances the position and mints the unanswered response. celld's
// `wrote()` refuses the gate outright when the request is not resident at the
// epoch that committed: durability cannot be proven for it, so it fails rather
// than falsely acknowledging.
pub tor cell.write { lease: string<lease>, data: string }
| committed string<pending!>
| not-resident
cell.write = if(own.epoch > 0)
| then |> std/store:stored { st.pos: st.pos + 1 } => committed data
| else => not-resident

// The replicator proves only what it has actually put in the bucket, so a
// demand to cover a position past the commit point comes back `behind`.
pub tor replica.sync { lease: string<lease>, upto: i64 }
| reached i64<durable!>
| behind
replica.sync = if(upto <= st.pos)
| then |> std/store:stored { st.synced: upto } => reached upto
| else => behind

// THE GATE. An acknowledgement consumes the response AND the proof.
pub tor gate.ack { r: string<!pending>, proof: i64<!durable> }
gate.ack = std/io:print.ln("  ack  {{ r:s }} — durable through {{ proof:d }}")

// The other way out. It needs no proof, because it acknowledges nothing.
pub tor gate.fail { r: string<!pending>, why: string }
gate.fail = std/io:print.ln("  fail {{ r:s }} — {{ why:s }}")

// One request, end to end. `ahead` is how far past the commit the caller
// insists the proof must reach — 0 is an honest replicator, 5 is a demand it
// cannot meet.
pub tor handle { lease: string<lease>, data: string, ahead: i64 }
handle = cell.write(lease, data)
| committed r |> std/io:print.ln("  held {{ data:s }} at pos {{ st.pos:d }} — response gated") |> replica.sync(lease, upto: st.pos + ahead)
    | reached p |> gate.ack(r, proof: p)
    | behind |> gate.fail(r, why: "durability unproven")
| not-resident |> std/io:print.ln("  not resident at commit epoch")

std/io:print.ln("node-a claims the cell")
cas.claim(node: "node-a", guard: 0)
| applied l |> handle(lease: l, data: "msg-1", ahead: 0) |> handle(lease: l, data: "msg-2", ahead: 5)
| rejected |> std/io:print.ln("  rejected")
