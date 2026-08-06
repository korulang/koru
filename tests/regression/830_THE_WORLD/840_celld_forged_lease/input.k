// The World in Koru — entry 8, negative twin two of 838_celld_lease_race.
// Doorway: celld's losing node — the one whose conditional PUT came back 412.
// Over there `cas_owner` returns `CasOutcome::Rejected` and it is up to the
// caller to honour it; the write path is an ordinary function and nothing in
// the type of a cell name says "you may not call this." Correctness rests on
// the caller checking the outcome.
//
// Here the losing branch simply has no token in it, and a lease cannot be
// conjured from a bare string. The check is not something the caller remembers
// to do — there is no spelling of the forgery that type-checks.
import std/io
import std/store

std/store:new(own, capacity: 1) { epoch: 0[i64], etag: 0[i64] }

pub tor cas.claim { node: string, guard: i64 }
| applied string<lease!>
| rejected

cas.claim = if(guard == own.etag)
| then |> std/store:stored { own.etag: own.etag + 1, own.epoch: own.epoch + 1 } => applied node
| else => rejected

pub tor cell.write { lease: string<lease>, cell: string, data: string }
cell.write = std/io:print.ln("  {{ lease:s }}  write e{{ own.epoch:d }} {{ cell:s }} <- {{ data:s }}")

pub tor cas.release { lease: string<!lease> }
cas.release = std/io:print.ln("  {{ lease:s }}  release")

// node-b lost the CAS. It tries to write anyway, forging a lease from a string.
std/store:stored { own.etag: 1 }
cas.claim(node: "node-b", guard: 0)
| applied l |> cell.write(lease: l, cell: "room-42", data: "legitimate")
| rejected |> cell.write(lease: "node-b", cell: "room-42", data: "forged")
