// dice.k — JavaDice, pure Koru. std/rand carries the randomness;
// the program is a prompt fold and a for.

import std/io
import std/string
import std/control
import std/rand

tor ask {}
| count i64
| miss
| quit

ask = std/io:print("How many dice (0 to exit): ") |> std/io:readln()
| line s |> std/string:parse-int(s)
    | ok n when n == 0 => quit
    | ok n when n < 0 => miss
    | ok n => count n
    | err _ => miss
| eof => quit
| failed _ => miss

#repl ask()
| count n |> for(0..n)
    ! each _ |> std/rand:between(lo: 1, hi: 7): f |> std/io:print("{{ f:d }} ")
    | done |> std/io:print.ln("") |> @repl()
| miss |> @repl()
| quit
