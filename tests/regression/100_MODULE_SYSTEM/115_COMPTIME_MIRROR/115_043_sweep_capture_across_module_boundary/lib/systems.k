// A system in a DIFFERENT module than the store, capturing a value per row.
import std/store

pub tor tick {} -> i64
tick -> 2

pub tor scale {}
scale = tick(): k |> std/store:query(items)
! query e |> std/store:stored { e.v: e.v * k }
