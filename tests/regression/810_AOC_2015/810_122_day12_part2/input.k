// AoC 2015 Day 12 Part 2 — sum numbers, but ignore any OBJECT (and its
// children) containing the value "red" (arrays with "red" still count).
// Statement examples: 6, 4, 0, 6.
//
// PURE .k, EMPTY LEDGER: a recursive-descent JSON walk built entirely from
// proven idioms — mutual/self value recursion (320_095) over a borrowed
// []const u8 + a SCALAR index (no owned collection, so no obligation
// threading needed). parse-val returns { sum, next, isred }; arr-sum and
// obj-sum fold over elements/pairs threading (index, running-sum) and, for
// objects, an OR'd red flag — at the closing '}' the object's whole sum is
// multiplied by (1 - red), zeroing a poisoned object and all its children.
// "red" is detected branchlessly (r,e,d between quotes); numbers carry an
// optional '-' sign. The flat part-1 char machine can't see object
// boundaries; this structural walk can.

import std/io
import std/fs

// Advance past a string: j points just AFTER the opening quote; returns the
// index just AFTER the closing quote.
pub tor skip-str { s: string, n: i64, j: i64 } -> i64

skip-str = if(j < n)
    | then |> if(s[@intCast(j)] == 34)
        | then -> j + 1
        | else |> skip-str(s, n, j: j + 1)
            | done k -> k
    | else -> j

// Consume a run of digits starting at i, folding into acc; returns { value, next }.
// NOTE: `acc` is declared BEFORE `i` on purpose. The emitter lowers this tail
// self-call to a while-loop that ASSIGNS the recursive args in parameter order
// (no simultaneous snapshot). `acc`'s new value reads s[i] with the OLD i, so
// `acc` must be assigned before `i` is bumped — declaring acc first makes the
// sequential lowering correct. (Reordering is the local workaround for the
// tail-loop arg-aliasing in commit c7337761; the general fix is to snapshot
// recursive args before assigning.)
pub tor num { s: string, n: i64, acc: i64, i: i64 } -> { sum: i64, next: i64 }

num = if(i < n)
    | then |> if(s[@intCast(i)] >= 48 and s[@intCast(i)] <= 57)
        | then |> num(s, n, acc: acc * 10 + @as(i64, s[@intCast(i)]) - 48, i: i + 1)
            | done r -> { r.sum, r.next }
        | else -> { sum: acc, next: i }
    | else -> { sum: acc, next: i }

// Parse one JSON value at index i. isred=1 iff this value is the string "red".
pub tor parse-val { s: string, n: i64, i: i64 } -> { sum: i64, next: i64, isred: i64 }

parse-val = if(s[@intCast(i)] == 91)
    | then |> arr-sum(s, n, i: i + 1, acc: 0)
        | done a -> { a.sum, a.next, isred: 0 }
    | else |> if(s[@intCast(i)] == 123)
        | then |> obj-sum(s, n, i: i + 1, acc: 0, red: 0)
            | done o -> { o.sum, o.next, isred: 0 }
        | else |> if(s[@intCast(i)] == 34)
            | then |> skip-str(s, n, j: i + 1)
                | done afterstr -> { sum: 0, next: afterstr, isred: @as(i64, @intFromBool(s[@intCast(i + 1)] == 114 and s[@intCast(i + 2)] == 101 and s[@intCast(i + 3)] == 100 and s[@intCast(i + 4)] == 34)) }
            | else |> num(s, n, i: i + @as(i64, @intFromBool(s[@intCast(i)] == 45)), acc: 0)
                | done m -> { sum: m.sum * (1 - 2 * @as(i64, @intFromBool(s[@intCast(i)] == 45))), m.next, isred: 0 }

// Fold an array's element values (arrays always count, even with "red").
// i points at the first element or at the closing ']'.
pub tor arr-sum { s: string, n: i64, i: i64, acc: i64 } -> { sum: i64, next: i64 }

arr-sum = if(s[@intCast(i)] == 93)
    | then -> { sum: acc, next: i + 1 }
    | else |> parse-val(s, n, i)
        | val e |> if(s[@intCast(e.next)] == 44)
            | then |> arr-sum(s, n, i: e.next + 1, acc: acc + e.sum)
                | done r -> { r.sum, r.next }
            | else |> arr-sum(s, n, i: e.next, acc: acc + e.sum)
                | done r -> { r.sum, r.next }

// Fold an object's value entries; if ANY value is "red", the whole object
// (and its children, already summed) contributes 0. i points at a key '"' or
// at the closing '}'.
pub tor obj-sum { s: string, n: i64, i: i64, acc: i64, red: i64 } -> { sum: i64, next: i64 }

obj-sum = if(s[@intCast(i)] == 125)
    | then -> { sum: acc * (1 - red), next: i + 1 }
    | else |> skip-str(s, n, j: i + 1)
        | done afterkey |> parse-val(s, n, i: afterkey + 1)
            | val v |> if(s[@intCast(v.next)] == 44)
                | then |> obj-sum(s, n, i: v.next + 1, acc: acc + v.sum, red: @max(red, v.isred))
                    | done r -> { r.sum, r.next }
                | else |> obj-sum(s, n, i: v.next, acc: acc + v.sum, red: @max(red, v.isred))
                    | done r -> { r.sum, r.next }

// Sum all numbers in one JSON line, skipping red-poisoned objects.
pub tor sum-no-red { s: string } -> i64

sum-no-red = capture { len: 0[i64] }
! as a |> for(s)
    ! each _ |> captured { len: a.len + 1 }
| captured r |> parse-val(s, n: r.len, i: 0)
    | val top -> top.sum

std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_122_day12_part2/input.txt")
! line l |> sum-no-red(s: l)
    | total t |> std/io:print.ln("{{ t:d }}")
| done _ |> _
| failed e |> std/io:print.ln("FAILED {{ e:s }}")
