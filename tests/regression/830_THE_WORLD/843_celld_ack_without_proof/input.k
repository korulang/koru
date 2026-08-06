// The World in Koru — entry 8 part two, negative twin one of 842.
// Doorway: celld acknowledging a write it has not replicated. Over there
// nothing in the TYPE of a response says "not yet" — `ReleaseResponse` takes a
// `Result` and will happily carry `Ok(())`. What stops a premature ack is that
// `durable_reached` is the only site that builds one, and it compares
// `durable >= gate.position` first (`logic/lib.rs:3711`). The guarantee lives
// in one function being careful, and would survive exactly as long as the next
// person to add a response path knows that.
//
// Here the proof is a value that only `replica.sync` can mint, and `gate.ack`
// requires it. There is no careful function to preserve: an acknowledgement
// with a made-up position is not a risky shortcut, it is not a program.
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

// Commit, then acknowledge with a position nobody proved.
cas.claim(node: "node-a", guard: 0)
| applied l |> cell.write(lease: l, data: "msg-1")
    | committed r |> gate.ack(r, proof: 99)
    | not-resident |> std/io:print.ln("  not resident")
| rejected |> std/io:print.ln("  rejected")
