// PINS: an interceptor's payload reaches a sweep arm nested in its body.
//
// This is the shape a store needs to maintain a SEPARATE index reactively:
// `! removed { id }` learns which entry left, then sweeps the index to find and
// invalidate it. Each half is green on its own and only the combination fails —
// measured 2026-07-28:
//
//   ! removed _     |> sweep(idx) ! query e when e.live == 1 |> stored {...}   compiles
//   ! removed { id } |> stored { idx[0].live: id }                             compiles
//   ! removed { id } |> sweep(idx) ! query e when e.id == id  |> stored {...}  THIS
//
// Two checkers go blind on the same fact. The backend reports `use of
// undeclared identifier 'id'` from the sweep's `when` guard, and KORU100
// independently reports "`! removed` binds 'id' but never uses it" — neither
// sees a use that lives inside the nested arm.
//
// CAUSE: sweep's capture pass collects enclosing MID-PIPE binds from the host
// flow (store.kz, `Cap.collectBindsOnPath` — the 690_073 mechanism). An
// interceptor payload is not a mid-pipe bind; it is the arm's payload on a
// transplanted interceptor body, so the walk never finds it and the name is
// never threaded into the sweepbody event.
import std/io
import std/store

std/store:new(idx, capacity: 8) { id: i64, live: i64 }

std/store:new(nodes, capacity: 8) { id: i64, val: i64 }
! removed { id } |> std/store:query(idx)
    ! query e when e.id == id |> std/store:stored { e.live: 0 }

std/store:insert(idx) { id: 10, live: 1 }
| row _ |> std/store:insert(idx) { id: 20, live: 1 }
    | row _ |> _
    | full |> _
| full |> _

std/store:insert(nodes) { id: 10, val: 100 }
| row a |> std/store:take(nodes[a])
    | item _ |> _
    | empty |> _

std/store:query(idx)
! query e |> std/io:print.ln("id {{ e.id:d }} live {{ e.live:d }}")
