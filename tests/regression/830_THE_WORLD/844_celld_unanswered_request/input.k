// The World in Koru — entry 8 part two, negative twin two of 842.
// Doorway: celld's fence draining the gates. When a node loses its lease it
// cannot answer anything it has gated, so `fence()` walks every pending write
// and completes it as FAILED (`logic/lib.rs:3838-3843`) — deliberately, in
// code, because the alternative is a caller waiting forever on a response that
// will never come. Dropping a gated write is the one thing the fence must not
// do, and nothing in Rust would have stopped it.
//
// Here the response is an obligation with TWO consumers, so the compiler
// refuses to pick one for you and the program must say which. Note what this
// is NOT: it is not auto-discharge quietly failing the request. It is the
// compiler declining to have an opinion about whether an unanswered request
// should be acked or failed — because both defaults are wrong.
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

pub tor cas.release { lease: string<!lease> }
cas.release = std/io:print.ln("  release {{ lease:s }}")

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

pub tor gate.ack { r: string<!pending>, proof: i64<!durable> }
gate.ack = std/io:print.ln("  ack {{ r:s }} — durable through {{ proof:d }}")

pub tor gate.fail { r: string<!pending>, why: string }
gate.fail = std/io:print.ln("  fail {{ r:s }} — {{ why:s }}")

// Commit, hold the response, and simply walk away from it.
cas.claim(node: "node-a", guard: 0)
| applied l |> cell.write(lease: l, data: "msg-1")
    | committed r |> std/io:print.ln("  committed, and never answered")
    | not-resident |> std/io:print.ln("  not resident")
| rejected |> std/io:print.ln("  rejected")
