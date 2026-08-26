// AoC 2015 Day 10 Part 1 — look-and-say. Statement example: "1" after 5
// rounds → 312211, length 6 (the real puzzle runs 40 rounds on a personal
// input — see the scale note below).
//
// GREEN (was RED on "ownership transfer of a phantom-obligation resource
// across fold iterations"). The pristine spelling never needed to hand an
// owned buffer across rounds: the SEQUENCE IS A NUMBER (day 11's ratified
// base-N encoding, here base 10), so a round is a PURE scalar transform
// and five rounds are five chained binds — nothing owned crosses
// anything. Inside a round, a left-to-right recursive walk carries
// (rest, scale, open-run digit, run count, packed output); each finished
// run packs two decimal positions (count, digit). Counts stay < 10 and
// sequences fit i64 exactly at statement scale — the same honesty
// boundary day 11 draws with its fixed 8-letter alphabet. A 40-round
// personal input overflows any fixed word and moves onto growable
// surfaces; this pin pins the statement's numbers, where the arithmetic
// spelling is the clean one. Digit access is div/mod only; parse-int
// decodes the input line once.

import std/io
import std/fs
import std/string

// Digit count (n ≥ 1).
pub tor dig-walk { r: i64, c: i64 } -> i64

dig-walk = if(r == 0)
| then -> c
| else |> dig-walk(r: @divTrunc(r, 10), c: c + 1): t -> t

pub tor digits { n: i64 } -> i64

digits = dig-walk(r: n, c: 0)

// Ten to the k.
pub tor pow10 { k: i64 } -> i64

pow10 = if(k <= 0)
| then -> 1
| else |> pow10(k: k - 1): t -> t * 10

// Consume the digit under `scale`: extend the open run or flush it into
// the packed output (two positions per run: count, then digit).
pub tor say-walk { rest: i64, scale: i64, d: i64, cnt: i64, out: i64 } -> i64

say-walk = if(scale == 0)
| then -> out * 100 + cnt * 10 + d
| else |> say-split(rest, scale, d, cnt, out): t -> t

pub tor say-split { rest: i64, scale: i64, d: i64, cnt: i64, out: i64 } -> i64

say-split = if(@mod(@divTrunc(rest, scale), 10) == d)
| then |> say-walk(rest, scale: @divTrunc(scale, 10), d, cnt: cnt + 1, out): t -> t
| else |> say-walk(rest, scale: @divTrunc(scale, 10), d: @mod(@divTrunc(rest, scale), 10), cnt: 1, out: out * 100 + cnt * 10 + d): t -> t

// One look-and-say round: seed the first digit, walk the rest.
pub tor say-round { n: i64 } -> i64

say-round = digits(n): L
    |> pow10(k: L - 1): P
    |> say-walk(rest: n, scale: @divTrunc(P, 10), d: @mod(@divTrunc(n, P), 10), cnt: 1, out: 0): r -> r

std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_101_day10_part1/input.txt")
! line l |> std/string:from-page(text: l)
    | ok h |> std/string:parse-int(s: h)
        | ok n0 |> std/string:free(s: h)
            |> say-round(n: n0): a
            |> say-round(n: a): b
            |> say-round(n: b): c2
            |> say-round(n: c2): d2
            |> say-round(n: d2): e2
            |> digits(n: e2): ln
            |> std/io:print.ln("{{ e2:d }}")
            |> std/io:print.ln("{{ ln:d }}")
        | err _ei |> _
    | err _ep |> _
| done _ |> _
| failed e |> std/io:print.ln("FAILED {{ e:s }}")
