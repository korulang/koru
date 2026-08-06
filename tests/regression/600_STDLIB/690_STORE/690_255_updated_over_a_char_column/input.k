// 690_255 — `! updated { old, new }` over a char[N] column: the PRE-IMAGE of a
// fixed-char cell is COPIED, not sliced in place.
//
// A scalar column's pre-image is one read: `const __koru_old = <col>[row]`.
// A char[N] column cannot be, because the cell IS the storage: a slice into it
// would be re-read AFTER the write and report the new bytes as the old ones.
// So the write path copies the whole `[N]u8` buffer to a local first, then
// slices THAT to the first NUL to make the `string`-shaped `old` the payload
// declares (store.kz:2786).
//
// The copy is USAGE-SYNTHESIZED, same (c)-lean as 690_003/690_038: only an
// `updated` arm that binds { old, new } materializes it; a discard arm
// (690_040) stays write-only and copies nothing.
//
// What this pins is that `old` and `new` DISAGREE. If the pre-image were a
// slice into the live cell rather than a copy of it, both would read
// "ship koru" and the line would be `relabel ship koru -> ship koru`.
//
// The store is single-column on purpose: the `updated` payload's type is taken
// from column 0 (store.kz:3920), so a char column in that slot is what types
// old/new as `string`.
import std/io
import std/store

std/store:new(todos, capacity: 8) { label: char[16] }
! updated { old, new } |> std/io:print.ln("relabel {{ old:s }} -> {{ new:s }}")

std/store:insert(todos) { label: "buy milk" }
| row r |> std/store:stored { todos[r].label: "ship koru" }
| full |> _
