// AoC 2015 Day 19 Part 2 — fewest steps to fabricate the molecule from e
// (statement: HOH → 3 steps). Greedy reverse-replacement leaf.
// Ledger: search ← host; rule table ← collections.

import std/io
import std/fs
import std/regex

pub event add-rule { line: string }

pub event fabricate { molecule: string }
| steps i64

std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_192_day19_part2/input.txt")
! line l |> std/regex:match(l)
    | `[A-Za-z]+ => [A-Za-z]+` _ |> add-rule(line: l)
    | `[A-Za-z]+` _ |> fabricate(molecule: l)
        | steps n |> std/io:print.ln("{{ n:d }}")
    | no-match |> _
| done _ |> _
| failed e |> std/io:print.ln("FAILED {{ e:s }}")
