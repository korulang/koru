// AoC 2015 Day 19 Part 1 — distinct molecules after ONE replacement.
// Statement: HOH with rules H=>HO, H=>OH, O=>HH → 4.
//
// Strings are little-endian base-3 numbers; digits pinned to the statement's
// element alphabet {H,O} -> {1,2} (the day-11 fixed-alphabet pin — a personal
// input with other elements moves to a wider alphabet and this pin says so).
// All collection work stays in flow scope: handles are created once up front,
// every read is `get-i64 | item`, every write is `push-i64`/`set:add` inside
// for/capture bodies — no user tor takes a collection parameter (the
// user-event borrow boundary is the KORU030 wall; 690_252 pins the flow-scope
// spelling this file uses).

import std/io
import std/fs
import std/regex
import std/list
import std/set

// element char -> digit (statement alphabet only)
pub tor dig { ch: i64 } -> i64

dig = if(ch == 'H')
| then -> 1
| else |> if(ch == 'O')
    | then -> 2
    | else -> 0

// string -> little-endian base-b code
pub tor encode { s: string, b: i64 } -> i64

encode = capture { code: 0[i64], pow: 1[i64] }
! as a |> for(s)
    ! each ch |> dig(ch): d
        |> captured { code: a.code + d * a.pow, pow: a.pow * b }
| captured r -> r.code

pub tor slen { s: string } -> i64

slen = capture { n: 0[i64] }
! as a |> for(s)
    ! each _ |> captured { n: a.n + 1 }
| captured r -> r.n

std/list:new-i64()
| list rules |> std/list:new-i64()
    | list pows |> std/list:new-i64()
        | list digs |> std/list:new-i64()
            | list hits |> std/set:new()
                | set seen |> std/list:push-i64(xs: pows, v: 1)
                    |> capture { pw: 1[i64] }
                        ! as pacc |> for(0..32)
                            ! each j |> std/list:push-i64(xs: pows, v: pacc.pw)
                                |> captured { pw: pacc.pw * 3 }
                        | captured _ |> std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_191_day19_part1/input.txt")
                            ! line l |> std/regex:match(l)
                                | `(?<f>[A-Za-z]+) => (?<t>[A-Za-z]+)` { f, t } |> slen(s: f): fl
                                    |> slen(s: t): tl
                                        |> encode(s: f, b: 3): fc
                                            |> encode(s: t, b: 3): tc
                                                |> std/list:push-i64(xs: rules, v: fl)
                                                    |> std/list:push-i64(xs: rules, v: tl)
                                                        |> std/list:push-i64(xs: rules, v: fc)
                                                            |> std/list:push-i64(xs: rules, v: tc)
                                | `(?<m>[A-Za-z]+)` { m } |> slen(s: m): ml
                                    |> encode(s: m, b: 3): mc
                                        |> for(0..@as(usize, @intCast(ml)))
                                            ! each j |> std/list:get-i64(xs: pows, i: j)
                                                | item pj |> std/list:push-i64(xs: digs, v: @mod(@divTrunc(mc, pj), 3))
                                                | out-of-bounds |> _
                                        |> std/list:len-i64(xs: rules): rl
                                            |> for(0..@as(usize, @intCast(ml * @divTrunc(@as(i64, @intCast(rl)), 4))))
                                                    ! each idx
                                                        |> capture { i: @divTrunc(@as(i64, @intCast(idx)), @divTrunc(@as(i64, @intCast(rl)), 4)), r: @mod(@as(i64, @intCast(idx)), @divTrunc(@as(i64, @intCast(rl)), 4)) }
                                                            ! as pos |> std/list:get-i64(xs: rules, i: @as(usize, @intCast(pos.r * 4)))
                                                                | item flen |> std/list:get-i64(xs: rules, i: @as(usize, @intCast(pos.r * 4 + 1)))
                                                                    | item tlen |> std/list:get-i64(xs: rules, i: @as(usize, @intCast(pos.r * 4 + 2)))
                                                                        | item from |> std/list:get-i64(xs: rules, i: @as(usize, @intCast(pos.r * 4 + 3)))
                                                                            | item tocode
                                                                                |> capture { ok: 1[i64] }
                                                                                    ! as mm |> for(0..@as(usize, @intCast(flen)))
                                                                                        ! each k |> std/list:get-i64(xs: digs, i: @as(usize, @intCast(pos.i)) + k)
                                                                                            | item dm |> std/list:get-i64(xs: pows, i: k)
                                                                                                | item pk |> captured { ok: mm.ok * @as(i64, @intFromBool(@mod(@divTrunc(from, pk), 3) == dm)) }
                                                                                                | out-of-bounds |> _
                                                                                            | out-of-bounds |> _
                                                                                    | captured mres
                                                                                            |> capture { pcode: 0[i64] }
                                                                                                ! as pc |> for(0..@as(usize, @intCast(ml - flen + tlen)))
                                                                                                    ! each q0 |> if(@as(i64, @intCast(q0)) < pos.i)
                                                                                                        | then |> std/list:get-i64(xs: digs, i: q0)
                                                                                                            | item sd |> std/list:get-i64(xs: pows, i: q0)
                                                                                                                | item pq |> captured { pcode: pc.pcode + sd * pq }
                                                                                                                | out-of-bounds |> _
                                                                                                        | else |> if(@as(i64, @intCast(q0)) < pos.i + tlen)
                                                                                                            | then |> std/list:get-i64(xs: pows, i: q0 - @as(usize, @intCast(pos.i)))
                                                                                                                | item pk2 |> std/list:get-i64(xs: pows, i: q0)
                                                                                                                    | item pq2 |> captured { pcode: pc.pcode + @mod(@divTrunc(tocode, pk2), 3) * pq2 }
                                                                                                                    | out-of-bounds |> _
                                                                                                            | else |> std/list:get-i64(xs: digs, i: q0 - @as(usize, @intCast(tlen)) + @as(usize, @intCast(flen)))
                                                                                                                | item sd2 |> std/list:get-i64(xs: pows, i: q0)
                                                                                                                    | item pq3 |> captured { pcode: pc.pcode + sd2 * pq3 }
                                                                                                                    | out-of-bounds |> _
                                                                                                | captured pres
                                                                                                    |> if(mres.ok == 1)
                                                                                                        | then |> std/set:contains(s: seen, v: pres.pcode)
                                                                                                            | yes |> _
                                                                                                            | no |> std/set:add(s: seen, v: pres.pcode)
                                                                                                                |> std/list:push-i64(xs: hits, v: pres.pcode)
                                            |> std/list:len-i64(xs: hits): hn
                                                |> std/io:print.ln("{{ @as(i64, @intCast(hn)):d }}")
                                | no-match |> slen(s: l): nl |> if(nl > 0)
                                    | then |> std/io:print.ln("BAD: {{ l:s }}")
                            | done _ |> std/set:free(s: seen)
                                |> std/list:free-i64(xs: hits)
                                    |> std/list:free-i64(xs: digs)
                                        |> std/list:free-i64(xs: pows)
                                            |> std/list:free-i64(xs: rules)
                            | failed e |> std/io:print.ln("FAILED {{ e:s }}")
                                |> std/set:free(s: seen)
                                    |> std/list:free-i64(xs: hits)
                                        |> std/list:free-i64(xs: digs)
                                            |> std/list:free-i64(xs: pows)
                                                |> std/list:free-i64(xs: rules)
                | err e0 |> std/io:print.ln("ERR0 {{ e0:s }}")
                    |> std/list:free-i64(xs: hits)
                            |> std/list:free-i64(xs: digs)
                                |> std/list:free-i64(xs: pows)
                                    |> std/list:free-i64(xs: rules)
            | err e1 |> std/io:print.ln("ERR1 {{ e1:s }}")
                |> std/list:free-i64(xs: digs)
                    |> std/list:free-i64(xs: pows)
                        |> std/list:free-i64(xs: rules)
        | err e2 |> std/io:print.ln("ERR2 {{ e2:s }}")
            |> std/list:free-i64(xs: pows)
                |> std/list:free-i64(xs: rules)
    | err e3 |> std/io:print.ln("ERR3 {{ e3:s }}")
        |> std/list:free-i64(xs: rules)
| err e4 |> std/io:print.ln("ERR4 {{ e4:s }}")
