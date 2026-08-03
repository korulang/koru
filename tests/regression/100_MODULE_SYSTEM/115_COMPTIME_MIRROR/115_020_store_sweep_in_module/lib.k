import std/io
import std/store

std/store:new(items, capacity: 8) { v: i64 }

pub tor seed-a {}
seed-a = std/store:insert(items) { v: 10 }

pub tor seed-b {}
seed-b = std/store:insert(items) { v: 20 }

pub tor seed-c {}
seed-c = std/store:insert(items) { v: 30 }

pub tor draw {}
draw = for(0..1)
! each _ |> std/store:query(items)
    ! query { [row]e, [ordinal]n } |> std/io:print.ln("row {{ n:d }} = {{ e.v:d }}")
