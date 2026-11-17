import std/io
import std/guides

pub tor probe {}
probe = std/guides:add("gadget -> error") { Module-resident lesson: check its own bindings first. }
    |> std/guides(gadget -> error)
    | guide t |> std/io:print.ln("mod {{ t:s }}")
    | not-found |> std/io:print.ln("mod MISS")
