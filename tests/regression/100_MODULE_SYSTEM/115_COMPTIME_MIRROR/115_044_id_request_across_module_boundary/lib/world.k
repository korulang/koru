// Components: the store is declared HERE, in its own module.
import std/io
import std/store

std/store:new(cells, capacity: 8) { v: i64, next: -1[i64] }
std/store:new(head) { h: -1[i64] }
std/store:new(probe) { v1: 0[i64] }

pub tor seed {}
seed = std/store:insert(cells) { v: 10, next: -1 }
| row _ |> std/store:insert(cells) { v: 20, next: -1 }
    | row _ |> std/store:insert(cells) { v: 30, next: -1 }
        | row _ |> _
        | full |> _
    | full |> _
| full |> _

// Read the chain head back through its handle and report. Same module as the
// store, so this half is not what the test is probing.
pub tor peek {}
// The read goes through a cell rather than straight into the interpolation:
// print.ln does not run the indexed-read lowering, which is its own gap.
peek = std/store:stored { probe.v1: cells[head.h].v }
    |> std/io:print.ln("head v {{ probe.v1:d }}")
