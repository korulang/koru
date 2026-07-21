// 690_052 — FIXED-CHAR column: `char[N]` — a fixed-length byte column in a
// container. Tier A of the string story (690_020 lineage): STATIC SoA
// (`[CAP][N]u8`), zero allocation, NO ownership (no take/discharge). Rides the
// typed-SoA-column work (690_049) — char[N] is just another column array type.
// This is the store shape a to-do TUI needs: a flag + a label.
// ASPIRATIONAL (see TODO): char[N] columns don't exist yet.
import std/io
import std/store

std/store:new(todos, capacity: 8) { done: i64, label: char[16] }

std/store:insert(todos) { done: 0, label: "buy milk" }
| row _ |> std/store:insert(todos) { done: 1, label: "ship koru" }
    | row _ |> _

std/store:query(todos)
! query { entity.done, entity.label } |> std/io:print.ln("[{{ done:d }}] {{ label:s }}")
