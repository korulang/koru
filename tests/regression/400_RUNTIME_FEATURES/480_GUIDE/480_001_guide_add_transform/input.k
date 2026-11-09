import std/guide
import std/io

std/guide:add(book-flight -> error) { When booking fails, check payment_methods first. }
std/guide:add(* -> error) { An edge fired unarmed — check vocabulary(). }

std/guide(book-flight -> error)
| guide t |> std/io:print.ln("{{ t:s }}")
| not-found |> std/io:print.ln("MISS")

std/guide(nonexistent -> error)
| guide t |> std/io:print.ln("{{ t:s }}")
| not-found |> std/io:print.ln("MISS")
