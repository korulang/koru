// AoC 2015 Day 22 — the two SCRIPTED statement fights, replayed exactly
// (fight 1: Poison, Magic Missile vs 13/8 → win, hp 2, mana 24; fight 2:
// the five-spell sequence vs 14/8 → win, hp 1, mana 114 — both end-states
// verbatim from the statement's turn narration). The actual puzzle ask
// (MINIMUM mana to win) is NOT pinned: a quick local BFS oracle disproved
// itself against the statement, and we do not pin against an untrusted
// oracle — min-mana lands when a trusted one exists. Ledger: turn engine
// ← host (effects/timers); spell-script parse ← groups.

import std/io
import std/fs

pub event fight { line: []const u8 }
| outcome []const u8

std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_221_day22_part1/input.txt")
! line l |> fight(line: l)
    | outcome o |> std/io:print.ln("{{ o:s }}")
| done _ |> _
| failed e |> std/io:print.ln("FAILED {{ e:s }}")
