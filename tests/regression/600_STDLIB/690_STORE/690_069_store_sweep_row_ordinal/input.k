// std/store:sweep with the reserved `row` ordinal — the layout cursor a
// retained renderer needs. A bare `row` in the projection (no `entity.` path)
// binds the 0-based row index; opt-in, so it's only present when the body uses
// it (KORU100-safe). `! draw |> sweep(store) ! sweep { entity.f, row } |>
// write-at(y: row, …)` is the render-bridge shape. Nested (the render-bridge
// position); top-level sweep is a separate follow-up (inline_code placement).
import std/io
import std/store
std/store:new(items, capacity: 8) { v: i64 }
std/store:insert(items) { v: 10 }
std/store:insert(items) { v: 20 }
std/store:insert(items) { v: 30 }
for(0..1)
! each _ |> std/store:sweep(items)
    ! sweep { entity.v, row } |> std/io:print.ln("row {{ row:d }} = {{ v:d }}")
