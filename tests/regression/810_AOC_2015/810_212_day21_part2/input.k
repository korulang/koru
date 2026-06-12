// AoC 2015 Day 21 Part 2 — priciest loadout that still LOSES.
// Boss stats are personal-only; this boss (104hp/8dmg/1armor) is
// CONSTRUCTED and python-oracled (priciest loss 148; the statement's demo
// boss 12/7/2 is degenerate — a bare dagger wins). Fight math is the
// statement's (ceil-turns comparison). Boss parse is Koru's now (named
// groups, typed destructure). Ledger: loadout search ← host.

import std/io
import std/fs
import std/regex

pub event shop { bh: i64, bd: i64, ba: i64, want-loss: i64 }
| gold i64

std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_212_day21_part2/input.txt")
! line l |> std/regex:match(l)
    | `(?<bh>[0-9]+) (?<bd>[0-9]+) (?<ba>[0-9]+)` { bh: i64, bd: i64, ba: i64 } |> shop(bh, bd, ba, want-loss: 1)
        | gold g |> std/io:print.ln("{{ g:d }}")
    | no-match |> std/io:print.ln("BAD LINE {{ l:s }}")
| done _ |> _
| failed e |> std/io:print.ln("FAILED {{ e:s }}")
