// The World in Koru — entry 8, negative twin three of 838_celld_lease_race.
// Doorway: celld's node-lease TTL. A node that acquires cells and then wedges
// would hold them forever, so celld defends with machinery: a 10-second lease,
// a renewal timer at ttl/3, a fence timer at ttl+1ms, and a self-fence that
// fails every pending write and halts the process with exit code 3
// (`logic/lib.rs:1838-1888`). All of that exists to answer one question — what
// if the owner never gives the lease back?
//
// Koru asks the question at compile time instead. This program mints <lease!>
// and declares no consumer of <!lease> anywhere, so there is no way back and
// nothing for auto-discharge to insert. A lease you cannot return is not a leak
// waiting to happen; it is a program that does not build.
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

// <lease!> is minted. Nothing in this program accepts <!lease>.
cas.claim(node: "node-a", guard: 0)
| applied l |> cell.write(lease: l, cell: "room-42", data: "held forever")
| rejected |> std/io:print.ln("  node-a  rejected")
