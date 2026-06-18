// std/map nested under a capture's <map!> obligation — the sibling of 660_019
// (set). Guards map against the capture-sequential-sibling double-discharge bug
// fixed in auto_discharge_inserter (329a55f2). set key 0 once => count 1; the
// <map!> must be discharged exactly ONCE, after the | captured after-read.
import std/io
import std/map

std/map:new()
| map m |> capture { x: 0[i64] }
    ! as pos |> captured { x: pos.x + 1 } |> std/map:set(m, k: pos.x, v: 100)
    | captured _ |> std/map:count(m)
        | count n |> std/io:print.ln("{{ n:d }}")
| err e |> std/io:print.ln("ERR {{ e:s }}")
