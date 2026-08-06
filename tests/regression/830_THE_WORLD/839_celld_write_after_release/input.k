// The World in Koru — entry 8, negative twin one of 838_celld_lease_race.
// Doorway: celld's fenced node — the owner that lost its lease and keeps
// writing. In celld this is not an error at all: the stale owner runs on, its
// writes land under a dead `e<epoch>` prefix, and the system stays correct
// because nobody will ever read them (`replication.rs:6`). The bug is real, the
// damage is contained, and the program never learns.
//
// Here the released token's type no longer carries <lease>, so the write path
// has no proof to borrow. Writing after you have given the lease back is not a
// wasted write — it is a compile error.
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

// Release the lease, then write with it anyway.
cas.claim(node: "node-a", guard: 0)
| applied l |> cas.release(lease: l) |> cell.write(lease: l, cell: "room-42", data: "after release")
| rejected |> std/io:print.ln("  node-a  rejected")
