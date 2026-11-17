import std/guides
import std/io

std/guides:add(book-flight -> error) { When booking fails, check payment_methods first. }
std/guides:add(* -> error) { An edge fired unarmed — check vocabulary(). }

std/guides(book-flight -> error)
| guide t |> std/io:print.ln("{{ t:s }}")
| not-found |> std/io:print.ln("MISS")

std/guides(nonexistent -> error)
| guide t |> std/io:print.ln("{{ t:s }}")
| not-found |> std/io:print.ln("MISS")
