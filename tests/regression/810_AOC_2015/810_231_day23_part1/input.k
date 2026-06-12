// AoC 2015 Day 23 — the register machine. The MACHINE LOOP is pure Koru:
// a top-level label fold threads (pc, a, b) through payloads, one decoded
// step per iteration — the 203 pattern driving a real VM. The statement
// example ends with a=2 (b untouched → 0). Ledger: instruction decode ←
// host (string-ops); program table ← store.

import std/io
import std/fs

pub event load { line: []const u8 }

pub event step { pc: i64, a: i64, b: i64 }
| cont { pc: i64, a: i64, b: i64 }
| halted { a: i64, b: i64 }

std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_231_day23_part1/input.txt")
! line l |> load(line: l)
| done _ |> _
| failed e |> std/io:print.ln("FAILED {{ e:s }}")

#run step(pc: 0, a: 0, b: 0)
| cont s |> @run(s.pc, s.a, s.b)
| halted r |> std/io:print.ln("a={{ r.a:d }} b={{ r.b:d }}")
