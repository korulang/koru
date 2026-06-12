// AoC 2015 Day 14 Part 2 — points: each second the leading reindeer gets
// a point; max points at t=1000 (statement: Dancer 689). The sentence parse
// is Koru's now (named groups, typed destructure); the per-second race
// over N reindeer still needs a TABLE of specs — ledgered to the store.

import std/io
import std/fs
import std/regex

pub event add-spec { speed: i64, fly: i64, rest: i64 }

pub event race { seconds: i64 }
| points i64

std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_142_day14_part2/input.txt")
! line l |> std/regex:match(l)
    | `[A-Za-z]+ can fly (?<speed>[0-9]+) km/s for (?<fly>[0-9]+) seconds, but then must rest for (?<rest>[0-9]+) seconds.` { speed: i64, fly: i64, rest: i64 } |> add-spec(speed, fly, rest)
    | no-match |> std/io:print.ln("BAD LINE {{ l:s }}")
| done _ |> race(seconds: 1000)
    | points p |> std/io:print.ln("{{ p:d }}")
| failed e |> std/io:print.ln("FAILED {{ e:s }}")
