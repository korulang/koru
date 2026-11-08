// AoC 2015 Day 7 Part 1 — wire circuit (statement: d=72 e=507 f=492 g=114
// h=65412 i=65079).
//
// The parked header's two gaps are both stale: no structured store is needed
// (wire names intern to i64 indices in std/string-map — the 810_092 idiom —
// and gate rules live in a stride-4 std/list), and no recursive eval is
// needed (the circuit is a DAG: fixpoint passes over the rule list resolve
// every wire, bounded by rule count). All collection work stays in flow
// scope — handles are created once, reads are get-i64|item / map:get|value,
// writes are push-i64 / map:set inside for bodies.
//
// Rule record (stride 4): [op, pa, pb, out]
//   op: 0 literal-assign, 1 AND, 2 OR, 3 LSHIFT, 4 RSHIFT, 5 NOT, 6 wire-copy
//   pa/pb packed operands: even = literal (p/2), odd = wire index (p/2)
//   out: raw wire index (interned, never packed)
// Wires live in std/map i64->i64; missing = unresolved.
// NOT is 16-bit: 65535 - (a & 65535); LSHIFT output masked & 65535.
// Map_i64_i64 borrows DO cross user-tor params (verified: scratch/aoc7/tmap.k)
// — resolve/evalop are scalar+borrow tors, the clean shape the KORU030 fix
// will generalize to lists/sets.

import std/io
import std/fs
import std/regex
import std/string
import std/string-map
import std/map
import std/list

// name -> interned index; inserts on first sight (810_092 dance)
pub tor intern { mm: *std/string-map:Map_string_i64<map>, tok: string } -> i64

intern = std/string-map:get(m: mm, k: tok)
| value idx -> idx
| missing |> std/string-map:count(m: mm): nb
    |> std/string-map:set(m: mm, k: tok, v: nb)
    |> std/string-map:get(m: mm, k: tok)
        | value i2 -> i2
        | missing -> 0

// operand token -> packed i64: literal*2 | wire-index*2+1
pub tor oper { mm: *std/string-map:Map_string_i64<map>, tok: string } -> i64

oper = std/string:parse-int(s: tok)
| ok v -> v * 2
| err _ |> std/string-map:get(m: mm, k: tok)
    | value idx -> idx * 2 + 1
    | missing |> std/string-map:count(m: mm): nb
        |> std/string-map:set(m: mm, k: tok, v: nb)
        |> std/string-map:get(m: mm, k: tok)
            | value i2 -> i2 * 2 + 1
            | missing -> 0

// packed operand -> value, or -1 when the wire is still unresolved
pub tor resolve { mm: *std/map:Map_i64_i64<map>, p: i64 } -> i64

resolve = if(@mod(p, 2) == 0)
| then -> @divTrunc(p, 2)
| else -> std/map:get(m: mm, k: @divTrunc(p, 2))
    | value v -> v
    | missing -> -1

// gate dispatch on resolved operands
pub tor evalop { op: i64, av: i64, bv: i64 } -> i64

evalop = if(op == 0)
| then -> av
| else |> if(op == 1)
    | then -> av & bv
    | else |> if(op == 2)
        | then -> av | bv
        | else |> if(op == 3)
            | then -> (av << @as(u6, @intCast(bv))) & 65535
            | else |> if(op == 4)
                | then -> av >> @as(u6, @intCast(bv))
                | else |> if(op == 5)
                    | then -> 65535 - (av & 65535)
                    | else -> av

std/string-map:new()
| map names |> std/list:new-i64()
    | list rules |> std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_071_day07_part1/input.txt")
        ! line l |> std/regex:match(l)
            | `(?<a>[a-z0-9]+) AND (?<b>[a-z0-9]+) -> (?<out>[a-z]+)` { a, b, out }
                |> oper(mm: names, tok: a): pa
                    |> oper(mm: names, tok: b): pb
                        |> intern(mm: names, tok: out): oi
                            |> std/list:push-i64(xs: rules, v: 1)
                                |> std/list:push-i64(xs: rules, v: pa)
                                    |> std/list:push-i64(xs: rules, v: pb)
                                        |> std/list:push-i64(xs: rules, v: oi)
            | `(?<a>[a-z0-9]+) OR (?<b>[a-z0-9]+) -> (?<out>[a-z]+)` { a, b, out }
                |> oper(mm: names, tok: a): pa
                    |> oper(mm: names, tok: b): pb
                        |> intern(mm: names, tok: out): oi
                            |> std/list:push-i64(xs: rules, v: 2)
                                |> std/list:push-i64(xs: rules, v: pa)
                                    |> std/list:push-i64(xs: rules, v: pb)
                                        |> std/list:push-i64(xs: rules, v: oi)
            | `(?<a>[a-z0-9]+) LSHIFT (?<n>[0-9]+) -> (?<out>[a-z]+)` { a, n: i64, out }
                |> oper(mm: names, tok: a): pa
                    |> intern(mm: names, tok: out): oi
                        |> std/list:push-i64(xs: rules, v: 3)
                            |> std/list:push-i64(xs: rules, v: pa)
                                |> std/list:push-i64(xs: rules, v: n * 2)
                                    |> std/list:push-i64(xs: rules, v: oi)
            | `(?<a>[a-z0-9]+) RSHIFT (?<n>[0-9]+) -> (?<out>[a-z]+)` { a, n: i64, out }
                |> oper(mm: names, tok: a): pa
                    |> intern(mm: names, tok: out): oi
                        |> std/list:push-i64(xs: rules, v: 4)
                            |> std/list:push-i64(xs: rules, v: pa)
                                |> std/list:push-i64(xs: rules, v: n * 2)
                                    |> std/list:push-i64(xs: rules, v: oi)
            | `NOT (?<a>[a-z0-9]+) -> (?<out>[a-z]+)` { a, out }
                |> oper(mm: names, tok: a): pa
                    |> intern(mm: names, tok: out): oi
                        |> std/list:push-i64(xs: rules, v: 5)
                            |> std/list:push-i64(xs: rules, v: pa)
                                |> std/list:push-i64(xs: rules, v: 0)
                                    |> std/list:push-i64(xs: rules, v: oi)
            | `(?<v>[0-9]+) -> (?<out>[a-z]+)` { v: i64, out }
                |> intern(mm: names, tok: out): oi
                    |> std/list:push-i64(xs: rules, v: 0)
                        |> std/list:push-i64(xs: rules, v: v * 2)
                            |> std/list:push-i64(xs: rules, v: 0)
                                |> std/list:push-i64(xs: rules, v: oi)
            | `(?<a>[a-z]+) -> (?<out>[a-z]+)` { a, out }
                |> oper(mm: names, tok: a): pa
                    |> intern(mm: names, tok: out): oi
                        |> std/list:push-i64(xs: rules, v: 6)
                            |> std/list:push-i64(xs: rules, v: pa)
                                |> std/list:push-i64(xs: rules, v: 0)
                                    |> std/list:push-i64(xs: rules, v: oi)
            | no-match |> std/io:print.ln("BAD: {{ l:s }}")
        | done _ |> std/map:new()
                | map vals |> std/list:len-i64(xs: rules): rl
                    |> for(0..@divTrunc(rl, 4))
                        ! each pp
                            |> for(0..@divTrunc(rl, 4))
                                ! each r
                                    |> std/list:get-i64(xs: rules, i: @as(usize, @intCast(r)) * 4)
                                        | item opv
                                            |> std/list:get-i64(xs: rules, i: @as(usize, @intCast(r)) * 4 + 1)
                                                | item pav
                                                    |> std/list:get-i64(xs: rules, i: @as(usize, @intCast(r)) * 4 + 2)
                                                        | item pbv
                                                            |> std/list:get-i64(xs: rules, i: @as(usize, @intCast(r)) * 4 + 3)
                                                                | item oi
                                                                    |> std/map:get(m: vals, k: oi)
                                                                        | value _ |> _
                                                                        | missing
                                                                            |> resolve(mm: vals, p: pav): av
                                                                                |> if(av >= 0)
                                                                                    | then
                                                                                        |> resolve(mm: vals, p: pbv): bv
                                                                                            |> if(bv >= 0)
                                                                                                | then
                                                                                                    |> evalop(op: opv, av, bv): res
                                                                                                        |> std/map:set(m: vals, k: oi, v: res)
                                                                | out-of-bounds |> _
                                                        | out-of-bounds |> _
                                                | out-of-bounds |> _
                                        | out-of-bounds |> _
                    |> std/string-map:get(m: names, k: "d")
                        | value didx
                            |> std/map:get(m: vals, k: didx)
                                | value dv |> std/io:print.ln("d={{ dv:d }}")
                                | missing |> std/io:print.ln("d=?")
                        | missing |> std/io:print.ln("d=?")
                    |> std/string-map:get(m: names, k: "e")
                        | value eidx
                            |> std/map:get(m: vals, k: eidx)
                                | value ev |> std/io:print.ln("e={{ ev:d }}")
                                | missing |> std/io:print.ln("e=?")
                        | missing |> std/io:print.ln("e=?")
                    |> std/string-map:get(m: names, k: "f")
                        | value fidx
                            |> std/map:get(m: vals, k: fidx)
                                | value fv |> std/io:print.ln("f={{ fv:d }}")
                                | missing |> std/io:print.ln("f=?")
                        | missing |> std/io:print.ln("f=?")
                    |> std/string-map:get(m: names, k: "g")
                        | value gidx
                            |> std/map:get(m: vals, k: gidx)
                                | value gv |> std/io:print.ln("g={{ gv:d }}")
                                | missing |> std/io:print.ln("g=?")
                        | missing |> std/io:print.ln("g=?")
                    |> std/string-map:get(m: names, k: "h")
                        | value hidx
                            |> std/map:get(m: vals, k: hidx)
                                | value hv |> std/io:print.ln("h={{ hv:d }}")
                                | missing |> std/io:print.ln("h=?")
                        | missing |> std/io:print.ln("h=?")
                    |> std/string-map:get(m: names, k: "i")
                        | value iidx
                            |> std/map:get(m: vals, k: iidx)
                                | value iv |> std/io:print.ln("i={{ iv:d }}")
                                | missing |> std/io:print.ln("i=?")
                        | missing |> std/io:print.ln("i=?")
                    |> std/map:free(m: vals)
                        |> std/string-map:free(m: names)
                            |> std/list:free-i64(xs: rules)
                | err e0 |> std/io:print.ln("ERR0 {{ e0:s }}")
                    |> std/string-map:free(m: names)
                        |> std/list:free-i64(xs: rules)
        | failed e1 |> std/io:print.ln("FAILED {{ e1:s }}")
            |> std/string-map:free(m: names)
                |> std/list:free-i64(xs: rules)
    | err e2 |> std/io:print.ln("ERR2 {{ e2:s }}")
        |> std/string-map:free(m: names)
| err e3 |> std/io:print.ln("ERR3 {{ e3:s }}")
