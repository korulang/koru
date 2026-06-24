// AoC 2015 Day 11 Part 1 — next valid password (abcdefgh → abcdffaa,
// ghijklmn → ghjaabcc). One next-password per input line. EMPTY LEDGER —
// pure .k: the password is carried as a SINGLE base-26 number n (8 letters,
// a=0..z=25, c0 most-significant), so the increment-until-valid SEARCH is a
// scalar label fold (#s/@s, 210_123) — no owned buffer threaded across
// iterations (which the obligation system can't yet do; see day 10). Each
// step tests validity by ARITHMETIC over the eight base-26 digits
// (digit k = (n / 26^(7-k)) mod 26):
//   • a straight of three  — some i with d[i+1]-d[i]==1 and d[i+2]-d[i+1]==1
//   • no i/o/l             — no digit equals 8, 14, or 11
//   • two distinct pairs   — >=2 different letters each appearing as d[i]==d[i+1]
//     (distinct letters can't overlap, so the "non-overlapping" rule reduces
//      to "the set of paired letters has >=2 elements").
// The result renders back to text via 26-char alphabet substrings appended
// into one growable String (a single outer instance — in-place mutation, which
// composes fine; only OWNED-buffer hand-off across iterations is the gap).

import std/io
import std/fs
import std/string

// Parse 8 letters into a base-26 number.
pub event to-n { s: []const u8 }
| value i64

to-n = capture { n: 0[i64] }
! as a |> for(s)
    ! each ch |> captured { n: a.n * 26 + (ch - 97) }
| captured r => value r.n

// One candidate: is `n` a valid password?
pub event istep { n: i64 }
| ok i64
| again i64

istep = if((((@mod(@divTrunc(n, 308915776), 26) - @mod(@divTrunc(n, 8031810176), 26) == 1 and @mod(@divTrunc(n, 11881376), 26) - @mod(@divTrunc(n, 308915776), 26) == 1) or (@mod(@divTrunc(n, 11881376), 26) - @mod(@divTrunc(n, 308915776), 26) == 1 and @mod(@divTrunc(n, 456976), 26) - @mod(@divTrunc(n, 11881376), 26) == 1) or (@mod(@divTrunc(n, 456976), 26) - @mod(@divTrunc(n, 11881376), 26) == 1 and @mod(@divTrunc(n, 17576), 26) - @mod(@divTrunc(n, 456976), 26) == 1) or (@mod(@divTrunc(n, 17576), 26) - @mod(@divTrunc(n, 456976), 26) == 1 and @mod(@divTrunc(n, 676), 26) - @mod(@divTrunc(n, 17576), 26) == 1) or (@mod(@divTrunc(n, 676), 26) - @mod(@divTrunc(n, 17576), 26) == 1 and @mod(@divTrunc(n, 26), 26) - @mod(@divTrunc(n, 676), 26) == 1) or (@mod(@divTrunc(n, 26), 26) - @mod(@divTrunc(n, 676), 26) == 1 and @mod(@divTrunc(n, 1), 26) - @mod(@divTrunc(n, 26), 26) == 1)) and ((@mod(@divTrunc(n, 8031810176), 26) != 8 and @mod(@divTrunc(n, 8031810176), 26) != 14 and @mod(@divTrunc(n, 8031810176), 26) != 11) and (@mod(@divTrunc(n, 308915776), 26) != 8 and @mod(@divTrunc(n, 308915776), 26) != 14 and @mod(@divTrunc(n, 308915776), 26) != 11) and (@mod(@divTrunc(n, 11881376), 26) != 8 and @mod(@divTrunc(n, 11881376), 26) != 14 and @mod(@divTrunc(n, 11881376), 26) != 11) and (@mod(@divTrunc(n, 456976), 26) != 8 and @mod(@divTrunc(n, 456976), 26) != 14 and @mod(@divTrunc(n, 456976), 26) != 11) and (@mod(@divTrunc(n, 17576), 26) != 8 and @mod(@divTrunc(n, 17576), 26) != 14 and @mod(@divTrunc(n, 17576), 26) != 11) and (@mod(@divTrunc(n, 676), 26) != 8 and @mod(@divTrunc(n, 676), 26) != 14 and @mod(@divTrunc(n, 676), 26) != 11) and (@mod(@divTrunc(n, 26), 26) != 8 and @mod(@divTrunc(n, 26), 26) != 14 and @mod(@divTrunc(n, 26), 26) != 11) and (@mod(@divTrunc(n, 1), 26) != 8 and @mod(@divTrunc(n, 1), 26) != 14 and @mod(@divTrunc(n, 1), 26) != 11)) and ((@intFromBool(@mod(@divTrunc(n, 8031810176), 26) == @mod(@divTrunc(n, 308915776), 26) and @mod(@divTrunc(n, 308915776), 26) == @mod(@divTrunc(n, 11881376), 26) and @mod(@divTrunc(n, 8031810176), 26) != @mod(@divTrunc(n, 308915776), 26)) + @intFromBool(@mod(@divTrunc(n, 8031810176), 26) == @mod(@divTrunc(n, 308915776), 26) and @mod(@divTrunc(n, 11881376), 26) == @mod(@divTrunc(n, 456976), 26) and @mod(@divTrunc(n, 8031810176), 26) != @mod(@divTrunc(n, 11881376), 26)) + @intFromBool(@mod(@divTrunc(n, 8031810176), 26) == @mod(@divTrunc(n, 308915776), 26) and @mod(@divTrunc(n, 456976), 26) == @mod(@divTrunc(n, 17576), 26) and @mod(@divTrunc(n, 8031810176), 26) != @mod(@divTrunc(n, 456976), 26)) + @intFromBool(@mod(@divTrunc(n, 8031810176), 26) == @mod(@divTrunc(n, 308915776), 26) and @mod(@divTrunc(n, 17576), 26) == @mod(@divTrunc(n, 676), 26) and @mod(@divTrunc(n, 8031810176), 26) != @mod(@divTrunc(n, 17576), 26)) + @intFromBool(@mod(@divTrunc(n, 8031810176), 26) == @mod(@divTrunc(n, 308915776), 26) and @mod(@divTrunc(n, 676), 26) == @mod(@divTrunc(n, 26), 26) and @mod(@divTrunc(n, 8031810176), 26) != @mod(@divTrunc(n, 676), 26)) + @intFromBool(@mod(@divTrunc(n, 8031810176), 26) == @mod(@divTrunc(n, 308915776), 26) and @mod(@divTrunc(n, 26), 26) == @mod(@divTrunc(n, 1), 26) and @mod(@divTrunc(n, 8031810176), 26) != @mod(@divTrunc(n, 26), 26)) + @intFromBool(@mod(@divTrunc(n, 308915776), 26) == @mod(@divTrunc(n, 11881376), 26) and @mod(@divTrunc(n, 11881376), 26) == @mod(@divTrunc(n, 456976), 26) and @mod(@divTrunc(n, 308915776), 26) != @mod(@divTrunc(n, 11881376), 26)) + @intFromBool(@mod(@divTrunc(n, 308915776), 26) == @mod(@divTrunc(n, 11881376), 26) and @mod(@divTrunc(n, 456976), 26) == @mod(@divTrunc(n, 17576), 26) and @mod(@divTrunc(n, 308915776), 26) != @mod(@divTrunc(n, 456976), 26)) + @intFromBool(@mod(@divTrunc(n, 308915776), 26) == @mod(@divTrunc(n, 11881376), 26) and @mod(@divTrunc(n, 17576), 26) == @mod(@divTrunc(n, 676), 26) and @mod(@divTrunc(n, 308915776), 26) != @mod(@divTrunc(n, 17576), 26)) + @intFromBool(@mod(@divTrunc(n, 308915776), 26) == @mod(@divTrunc(n, 11881376), 26) and @mod(@divTrunc(n, 676), 26) == @mod(@divTrunc(n, 26), 26) and @mod(@divTrunc(n, 308915776), 26) != @mod(@divTrunc(n, 676), 26)) + @intFromBool(@mod(@divTrunc(n, 308915776), 26) == @mod(@divTrunc(n, 11881376), 26) and @mod(@divTrunc(n, 26), 26) == @mod(@divTrunc(n, 1), 26) and @mod(@divTrunc(n, 308915776), 26) != @mod(@divTrunc(n, 26), 26)) + @intFromBool(@mod(@divTrunc(n, 11881376), 26) == @mod(@divTrunc(n, 456976), 26) and @mod(@divTrunc(n, 456976), 26) == @mod(@divTrunc(n, 17576), 26) and @mod(@divTrunc(n, 11881376), 26) != @mod(@divTrunc(n, 456976), 26)) + @intFromBool(@mod(@divTrunc(n, 11881376), 26) == @mod(@divTrunc(n, 456976), 26) and @mod(@divTrunc(n, 17576), 26) == @mod(@divTrunc(n, 676), 26) and @mod(@divTrunc(n, 11881376), 26) != @mod(@divTrunc(n, 17576), 26)) + @intFromBool(@mod(@divTrunc(n, 11881376), 26) == @mod(@divTrunc(n, 456976), 26) and @mod(@divTrunc(n, 676), 26) == @mod(@divTrunc(n, 26), 26) and @mod(@divTrunc(n, 11881376), 26) != @mod(@divTrunc(n, 676), 26)) + @intFromBool(@mod(@divTrunc(n, 11881376), 26) == @mod(@divTrunc(n, 456976), 26) and @mod(@divTrunc(n, 26), 26) == @mod(@divTrunc(n, 1), 26) and @mod(@divTrunc(n, 11881376), 26) != @mod(@divTrunc(n, 26), 26)) + @intFromBool(@mod(@divTrunc(n, 456976), 26) == @mod(@divTrunc(n, 17576), 26) and @mod(@divTrunc(n, 17576), 26) == @mod(@divTrunc(n, 676), 26) and @mod(@divTrunc(n, 456976), 26) != @mod(@divTrunc(n, 17576), 26)) + @intFromBool(@mod(@divTrunc(n, 456976), 26) == @mod(@divTrunc(n, 17576), 26) and @mod(@divTrunc(n, 676), 26) == @mod(@divTrunc(n, 26), 26) and @mod(@divTrunc(n, 456976), 26) != @mod(@divTrunc(n, 676), 26)) + @intFromBool(@mod(@divTrunc(n, 456976), 26) == @mod(@divTrunc(n, 17576), 26) and @mod(@divTrunc(n, 26), 26) == @mod(@divTrunc(n, 1), 26) and @mod(@divTrunc(n, 456976), 26) != @mod(@divTrunc(n, 26), 26)) + @intFromBool(@mod(@divTrunc(n, 17576), 26) == @mod(@divTrunc(n, 676), 26) and @mod(@divTrunc(n, 676), 26) == @mod(@divTrunc(n, 26), 26) and @mod(@divTrunc(n, 17576), 26) != @mod(@divTrunc(n, 676), 26)) + @intFromBool(@mod(@divTrunc(n, 17576), 26) == @mod(@divTrunc(n, 676), 26) and @mod(@divTrunc(n, 26), 26) == @mod(@divTrunc(n, 1), 26) and @mod(@divTrunc(n, 17576), 26) != @mod(@divTrunc(n, 26), 26)) + @intFromBool(@mod(@divTrunc(n, 676), 26) == @mod(@divTrunc(n, 26), 26) and @mod(@divTrunc(n, 26), 26) == @mod(@divTrunc(n, 1), 26) and @mod(@divTrunc(n, 676), 26) != @mod(@divTrunc(n, 26), 26))) >= 1)))
| then => ok n
| else => again n

// Search: from n0, increment until a valid password is found.
pub event seek { n: i64 }
| found i64

seek = #s istep(n)
| again m |> @s(n: m + 1)
| ok r => found r

std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_111_day11_part1/input.txt")
! line l |> to-n(s: l)
    | value n0 |> seek(n: n0 + 1)
        | found n |> std/string:from-page("abcdefghijklmnopqrstuvwxyz")
            | ok alpha |> std/string:from-page("")
                | ok base |> std/string:take(base): buf |> for(0..8)
                        ! each k |> std/string:substring(alpha, start: @mod(@divTrunc(@as(usize, @intCast(n)), 8031810176 * @as(usize, @intFromBool(k == 0)) + 308915776 * @as(usize, @intFromBool(k == 1)) + 11881376 * @as(usize, @intFromBool(k == 2)) + 456976 * @as(usize, @intFromBool(k == 3)) + 17576 * @as(usize, @intFromBool(k == 4)) + 676 * @as(usize, @intFromBool(k == 5)) + 26 * @as(usize, @intFromBool(k == 6)) + 1 * @as(usize, @intFromBool(k == 7))), 26), end: @mod(@divTrunc(@as(usize, @intCast(n)), 8031810176 * @as(usize, @intFromBool(k == 0)) + 308915776 * @as(usize, @intFromBool(k == 1)) + 11881376 * @as(usize, @intFromBool(k == 2)) + 456976 * @as(usize, @intFromBool(k == 3)) + 17576 * @as(usize, @intFromBool(k == 4)) + 676 * @as(usize, @intFromBool(k == 5)) + 26 * @as(usize, @intFromBool(k == 6)) + 1 * @as(usize, @intFromBool(k == 7))), 26) + 1)
                            | ok cs |> std/string:read(cs): csl |> std/string:append(s: buf, text: csl)
                                    | ok |> std/string:free(cs)
                                    | err _ |> std/string:free(cs)
                            | err _ |> _
                        | done |> std/string:read(buf): all |> std/io:print.ln("{{ all:s }}") |> std/string:free(buf) |> std/string:free(alpha)
                | err _ |> std/string:free(alpha)
            | err _ |> _
| done _ |> _
| failed e |> std/io:print.ln("FAILED {{ e:s }}")
