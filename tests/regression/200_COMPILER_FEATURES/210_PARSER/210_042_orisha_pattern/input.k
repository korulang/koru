// Reproduce Orisha pattern exactly:
// ~module:event()
//   | branch |>
//     module:other_event()

import std/io

if(cond: true)
  | then |> std/io:print.ln("then branch")
  | else |> std/io:print.ln("else branch")
