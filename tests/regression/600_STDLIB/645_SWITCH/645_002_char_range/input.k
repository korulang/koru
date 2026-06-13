// std/switch:char range dispatch. `a-z` is inclusive; values inside the range
// bind the matched char, values outside fall to `no-match`.
import std/switch
import std/io

std/switch:char('m')
| `a-z` c |> if(c == 'm')
    | then |> std/io:print.ln("matched-m")
    | else |> std/io:print.ln("lower")
| no-match |> std/io:print.ln("other")

std/switch:char('M')
| `a-z` c |> if(c == 'm')
    | then |> std/io:print.ln("matched-m")
    | else |> std/io:print.ln("lower")
| no-match |> std/io:print.ln("other")
