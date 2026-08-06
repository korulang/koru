// The World in Koru — entry 8 part two, negative twin three of 842.
// Doorway: celld's drained-gate guard. `durable_reached` opens with
//
//     let Some(gate) = self.gated_writes.remove(&op) else { return; };
//
// and its comment names the hazard exactly: "A completion for a gate already
// drained (fence or deadline) is ignored." A durability completion can arrive
// for a request the fence already failed, and answering it a second time would
// hand the caller two contradictory outcomes for one write. celld defends with
// a versioned-op discipline applied by hand at every such site.
//
// Here answering consumes the response, so the second answer has nothing left
// to consume. The discipline is not applied at each site; there is no second
// site.
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

// Acknowledge the write, then also fail it.
cas.claim(node: "node-a", guard: 0)
| applied l |> cell.write(lease: l, data: "msg-1")
    | committed r |> replica.sync(lease: l, upto: st.pos)
        | reached p |> gate.ack(r, proof: p) |> gate.fail(r, why: "fenced")
        | behind |> gate.fail(r, why: "behind")
    | not-resident |> std/io:print.ln("  not resident")
| rejected |> std/io:print.ln("  rejected")
