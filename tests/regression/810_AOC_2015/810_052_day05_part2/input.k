// AoC 2015 Day 5 Part 2 — new niceness: (1) a two-letter pair appears
// twice without overlap (xyxy), (2) a letter repeats with one between
// (xyx). qjhvhtzxzqqjkmpb + xxyxx nice; the other two naughty → 2.
// Ledger (FAT, deliberately): both predicates are host leaves — the
// pure-regex spelling ((..).*\1 as 676 alternations) exceeds the DFA
// engine's deliberate state cap (DfaTooLarge, loud + named since
// 2026-06-12; 640_004 pinned the old silent ceiling). These leaves become
// two match arms when the engine grows a huge-alternation strategy
// (lazy DFA / NFA simulation) — tracked in FRONTIERS.

import std/io
import std/fs

pub event nice2 { s: string }
| yes
| no

capture { nice: 0[i64] }
! as acc |> std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_052_day05_part2/input.txt")
    ! line l |> nice2(s: l)
        | yes |> captured { nice: acc.nice + 1 }
        | no |> _
    | done _ |> _
    | failed e |> std/io:print.ln("FAILED {{ e:s }}")
| captured total |> std/io:print.ln("{{ total.nice:d }}")
