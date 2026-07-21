// 690_056 — the *File<open!> proof: the owned-column generalization on a REAL
// pre-existing corpus resource (app/fs's *File<opened!>, open!/close — green
// across 330_006/013/…), not a purpose-built type. A store column holds
// *app/lib/fs:File<opened!>; insert moves ownership IN, take moves it OUT (then
// close), and store teardown auto-CLOSES each still-live file via the DISCOVERED
// canonical discharger `close`. Resource-agnostic: the store hardcodes nothing.
import std/io
import std/store
import app/lib/fs

std/store:new(files, capacity: 8) { handle: *app/lib/fs:File<opened!> }

app/lib/fs:open(path: "a"): f |> std/store:insert(files) { handle: f }
    | row r |> std/store:take(files[r])
        | item it |> app/lib/fs:close(file: it.handle) |> std/io:print.ln("took-and-closed")

app/lib/fs:open(path: "b"): kept |> std/store:insert(files) { handle: kept }
    | row _ |> _
