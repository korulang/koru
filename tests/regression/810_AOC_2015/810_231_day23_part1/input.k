// AoC 2015 Day 23 — the register machine, pure Koru. The program is parsed into
// three parallel [8]i64 arrays (opcode / register / offset) held in a capture,
// then THREADED through `run` — an if-value-return recursion (the day18 pattern)
// that decodes one instruction per call and recurses until pc leaves the
// program. Opcodes: hlf 0, tpl 1, inc 2, jmp 3, jie 4, jio 5. Register a=0/b=1
// (from the matched name byte, r[0]-97). The decode is a chain of `captured`
// writes (each sees the previous), so the dispatch stays branchless but readable.
// Statement example ends a=2, b=0.

import std/io
import std/fs
import std/regex

pub tor run { pc: i64, a: i64, b: i64, ops: [8]i64, regs: [8]i64, offs: [8]i64, n: i64 } -> { a: i64, b: i64 }

run = if(pc >= n or pc < 0)
| then -> { a, b }
| else |> capture { o: 0[i64], rg: 0[i64], of: 0[i64], rv: 0[i64], nrv: 0[i64], sa: 0[i64], sb: 0[i64], tj: 0[i64], na: 0[i64], nb: 0[i64], np: 0[i64] }
    ! as s |> captured { o: ops[@as(usize, @intCast(pc))], rg: regs[@as(usize, @intCast(pc))], of: offs[@as(usize, @intCast(pc))] } |> captured { rv: a * (1 - s.rg) + b * s.rg } |> captured { nrv: @divTrunc(s.rv, 2) * @as(i64, @intFromBool(s.o == 0)) + s.rv * 3 * @as(i64, @intFromBool(s.o == 1)) + (s.rv + 1) * @as(i64, @intFromBool(s.o == 2)) + s.rv * @as(i64, @intFromBool(s.o >= 3)) } |> captured { sa: @as(i64, @intFromBool(s.o <= 2)) * (1 - s.rg), sb: @as(i64, @intFromBool(s.o <= 2)) * s.rg, tj: @as(i64, @intFromBool(s.o == 3)) + @as(i64, @intFromBool(s.o == 4)) * @as(i64, @intFromBool(@mod(s.rv, 2) == 0)) + @as(i64, @intFromBool(s.o == 5)) * @as(i64, @intFromBool(s.rv == 1)) } |> captured { na: a * (1 - s.sa) + s.nrv * s.sa, nb: b * (1 - s.sb) + s.nrv * s.sb, np: pc + s.of * s.tj + (1 - s.tj) }
    | captured r |> run(pc: r.np, a: r.na, b: r.nb, ops, regs, offs, n): res -> res

capture { op: [8]i64{ 0, 0, 0, 0, 0, 0, 0, 0 }, reg: [8]i64{ 0, 0, 0, 0, 0, 0, 0, 0 }, off: [8]i64{ 0, 0, 0, 0, 0, 0, 0, 0 }, idx: 0[i64] }
! as acc |> std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_231_day23_part1/input.txt")
    ! line l |> std/regex:match(l)
        | `hlf (?<r>a|b)` { r: string } |> captured { op[@as(usize, @intCast(acc.idx))]: 0, reg[@as(usize, @intCast(acc.idx))]: @as(i64, r[0]) - 97, off[@as(usize, @intCast(acc.idx))]: 0, idx: acc.idx + 1 }
        | `tpl (?<r>a|b)` { r: string } |> captured { op[@as(usize, @intCast(acc.idx))]: 1, reg[@as(usize, @intCast(acc.idx))]: @as(i64, r[0]) - 97, off[@as(usize, @intCast(acc.idx))]: 0, idx: acc.idx + 1 }
        | `inc (?<r>a|b)` { r: string } |> captured { op[@as(usize, @intCast(acc.idx))]: 2, reg[@as(usize, @intCast(acc.idx))]: @as(i64, r[0]) - 97, off[@as(usize, @intCast(acc.idx))]: 0, idx: acc.idx + 1 }
        | `jmp (?<o>[+-][0-9]+)` { o: i64 } |> captured { op[@as(usize, @intCast(acc.idx))]: 3, reg[@as(usize, @intCast(acc.idx))]: 0, off[@as(usize, @intCast(acc.idx))]: o, idx: acc.idx + 1 }
        | `jie (?<r>a|b), (?<o>[+-][0-9]+)` { r: string, o: i64 } |> captured { op[@as(usize, @intCast(acc.idx))]: 4, reg[@as(usize, @intCast(acc.idx))]: @as(i64, r[0]) - 97, off[@as(usize, @intCast(acc.idx))]: o, idx: acc.idx + 1 }
        | `jio (?<r>a|b), (?<o>[+-][0-9]+)` { r: string, o: i64 } |> captured { op[@as(usize, @intCast(acc.idx))]: 5, reg[@as(usize, @intCast(acc.idx))]: @as(i64, r[0]) - 97, off[@as(usize, @intCast(acc.idx))]: o, idx: acc.idx + 1 }
        | no-match |> _
    | done _ |> run(pc: 0, a: 0, b: 0, ops: acc.op, regs: acc.reg, offs: acc.off, n: acc.idx): res |> std/io:print.ln("a={{ res.a:d }} b={{ res.b:d }}")
    | failed e |> std/io:print.ln("FAILED {{ e:s }}")
| captured _ |> _
