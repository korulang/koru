// AoC 2015 Day 16 Part 1 — which Sue matches the MFCSAM readout (exact
// match on every listed property). The real input is personal-only, so
// these Sues are CONSTRUCTED from the statement's readout with exactly
// one match per part (hand-derived: part 1 → Sue 2, part 2 → Sue 1).
// Ledger: property compare ← collections/groups; per-line dispatch is Koru.

import std/io
import std/fs

pub event check-sue { line: []const u8, ranged: i64 }
| match i64
| no

std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_161_day16_part1/input.txt")
! line l |> check-sue(line: l, ranged: 0)
    | match n |> std/io:print.ln("{{ n:d }}")
    | no |> _
| done _ |> _
| failed e |> std/io:print.ln("FAILED {{ e:s }}")
