// Rosetta "Towers of Hanoi" — the published 3-disk move trace (7 moves,
// pegs A B C). PURE .k, empty ledger. The decomposition IS the proof: a
// tor whose subflow recurses twice with a printed move between the halves
// — non-tail tree recursion with an interleaved effect — and returns its
// move count, so the caller verifies 2^3 - 1 = 7 rather than trusting the
// trace length.

import std/io

pub tor hanoi { n: i64, from: string, to: string, spare: string } -> i64

hanoi = if(n == 0)
| then -> 0
| else |> hanoi(n: n - 1, from, to: spare, spare: to): a
    |> std/io:print.ln("disk {{ n:d }}: {{ from:s }} -> {{ to:s }}")
    |> hanoi(n: n - 1, from: spare, to, spare: from): b -> a + 1 + b

std/io:print.ln("Towers of Hanoi — 3 disks, A to C:")
hanoi(n: 3, from: "A", to: "C", spare: "B"): n
|> std/io:print.ln("{{ n:d }} moves total")
