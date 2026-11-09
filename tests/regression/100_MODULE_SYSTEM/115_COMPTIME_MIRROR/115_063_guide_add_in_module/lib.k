import std/io
import std/guide

pub tor probe {}
probe = std/guide:add("gadget -> error") { Module-resident lesson: check its own bindings first. }
    |> std/guide(gadget -> error)
    | guide t |> std/io:print.ln("mod {{ t:s }}")
    | not-found |> std/io:print.ln("mod MISS")
