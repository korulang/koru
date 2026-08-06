// The World in Koru — entry 8.
// Doorway: celld's ownership lease — `cas_owner()` + the epoch fence, from
// Deno's self-hosted Durable Objects (github.com/denoland/celld, Rust).
//
// Over there, a cell's owner is one object in an S3 bucket,
// `cells/<cell>/own.json` = `{ node, epoch }`, claimed by a conditional PUT:
// If-None-Match to create, If-Match to take over (`bucket.rs:205-233`). A
// takeover bumps the epoch (`logic/lib.rs:2812`), and the epoch is baked into
// the object PREFIX — `cells/<cell>/ltx/e<epoch>/` — so, in their words,
// "epoch-in-prefix is the data-path fence: a stale owner writes a dead prefix"
// (`replication.rs:6`). No consensus, no membership protocol, no failure
// detector. The bucket is the coordinator, and one atomic write is the whole
// election.
//
// It is a beautiful fence, and it is a fence made of CONSEQUENCE. A node that
// lost the CAS still runs. It still calls its write path. It is merely writing
// somewhere nobody will ever read. Correctness arrives after the fact, as a
// property of where the bytes landed.
//
// Here in Koru the lease is an OBLIGATION, so it arrives before the fact.
// `cas.claim` is the only minter of `<lease!>`; `cell.write` BORROWS `<lease>`
// on an input, so it cannot be entered without proof of ownership; `cas.release`
// consumes `<!lease>`, retiring the proof. The stale owner does not write a dead
// prefix. The stale owner does not compile — see the three negative twins,
// 839 (use after release), 840 (forged lease), 841 (a lease with no way back).
//
// LANGUAGE CORNER: 834/835 exercise obligations as mint-then-consume — a lock
// you take and give back. This entry exercises the third form, the BORROW: an
// input typed `<lease>` reads the token without discharging it, so one lease
// admits many writes and no lease admits none. That is capability-as-type, and
// nothing else in the catalog uses it.
import std/io
import std/store

// ── THE BUCKET ──────────────────────────────────────────────────────────────
// One row: the owner record. `etag` is the version a conditional PUT compares;
// `epoch` is the fence that rides in the object prefix. In-memory and
// deterministic — which is also celld's own posture, since the crate holding
// their entire distributed protocol declares "no async, I/O, clocks,
// randomness, locks, or dependencies."
std/store:new(own, capacity: 1) { epoch: 0[i64], etag: 0[i64] }

// ── THE CAS ─────────────────────────────────────────────────────────────────
// The only minter of <lease!>. On a win the record is rewritten — etag advances,
// epoch bumps — and the winner receives a token. On a loss the caller gets a
// branch with no token in it, and there is nothing downstream of `rejected`
// that can reach the data path.
pub tor cas.claim { node: string, guard: i64 }
| applied string<lease!>
| rejected

cas.claim = if(guard == own.etag)
| then |> std/store:stored { own.etag: own.etag + 1, own.epoch: own.epoch + 1 } => applied node
| else => rejected

// ── THE DATA PATH ───────────────────────────────────────────────────────────
// BORROWS <lease>: reads the token, does not retire it.
pub tor cell.write { lease: string<lease>, cell: string, data: string }
cell.write = std/io:print.ln("  {{ lease:s }}  write e{{ own.epoch:d }} {{ cell:s }} <- {{ data:s }}")

// ── THE RELEASE ─────────────────────────────────────────────────────────────
// CONSUMES <!lease>, the way celld's `release_owner` blanks the record so the
// next node can claim without waiting out a lease TTL.
pub tor cas.release { lease: string<!lease> }
cas.release = std/io:print.ln("  {{ lease:s }}  release")

// ── A TWO-NODE RACE ─────────────────────────────────────────────────────────

// node-a claims the fresh record and hands it back cleanly.
std/io:print.ln("node-a  cas guard=0")
cas.claim(node: "node-a", guard: 0)
| applied la |> cell.write(lease: la, cell: "room-42", data: "hello from a") |> cas.release(lease: la)
| rejected |> std/io:print.ln("  node-a  rejected")

// node-b races on a STALE guard — it read the record before node-a's write.
// This is the whole of compare-and-swap: no lock, no lease timer, no
// coordinator. The etag moved, so the write does not apply.
std/io:print.ln("node-b  cas guard=0 (stale)")
cas.claim(node: "node-b", guard: 0)
| applied lb |> cell.write(lease: lb, cell: "room-42", data: "hello from b")
| rejected |> std/io:print.ln("  node-b  rejected — etag moved")

// node-b re-reads and takes over at the current etag. NO release is written
// here: auto-discharge inserts it at scope exit, so a lease cannot be leaked
// even by forgetting. celld needs a 10-second node-lease TTL, a renewal timer,
// and a self-fence that halts the process (`logic/lib.rs:1838-1888`) to get the
// same property at runtime.
std/io:print.ln("node-b  cas guard={{ own.etag:d }} (takeover)")
cas.claim(node: "node-b", guard: own.etag)
| applied lb2 |> cell.write(lease: lb2, cell: "room-42", data: "hello from b")
| rejected |> std/io:print.ln("  node-b  rejected")
