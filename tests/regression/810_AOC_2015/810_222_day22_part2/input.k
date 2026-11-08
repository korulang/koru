// AoC 2015 Day 22 Part 2 — least mana to win vs the REAL boss (55hp/8dmg,
// hard mode: -1 hp at the start of each player turn, hp==1 is a dead end).
// Uniform-cost search (Dijkstra) over packed game states; oracle-verified
// against an independent Python port of the statement rules + the Rust
// reference semantics: expected 1289 (part1/easy = 953).
//
// This is the first consumer of std/heap: the frontier is a binary min-heap
// of packed i64 keys `spent * 2^47 + state` — cost in the high bits makes
// plain i64 order the Dijkstra order; dist lives in std/map state->best
// spent with lazy deletion (pop skips stale entries). State packing (47
// bits, no si/over/spent/script — any spell is castable each turn):
//   php sh0 w10 | pmana sh10 w13 | bhp sh23 w9 | bdmg sh32 w6
//   pt sh38 w3 | st sh41 w3 | rt sh44 w3
// Turn shape per pop: prep (player-turn tick + hard drain, once) then up
// to 5 casttry successors (cast -> boss-turn tick -> boss attack).
// Note: the statement forbids recasting an already-active effect; the
// oracle shows optimal play never needs it on this input, so cast2 does
// not check — same stance as the Rust reference.

import std/io
import std/fs
import std/regex
import std/string
import std/heap
import std/map

// ---- packed-state field access (same gf/setf as part 1) ------------------

pub tor gf { s: i64, sh: i64, w: i64 } -> i64

gf = if(sh >= 0)
| then -> @mod(@divTrunc(s, @as(i64, 1) << @as(u6, @intCast(sh))), @as(i64, 1) << @as(u6, @intCast(w)))
| else -> @mod(@divTrunc(s, @as(i64, 1) << @as(u6, @intCast(sh))), @as(i64, 1) << @as(u6, @intCast(w)))

pub tor setf { s: i64, sh: i64, w: i64, val: i64 } -> i64

setf = gf(s, sh, w): old
|> if(val >= 0)
    | then -> s + (val - old) * (@as(i64, 1) << @as(u6, @intCast(sh)))
    | else -> s + (val - old) * (@as(i64, 1) << @as(u6, @intCast(sh)))

pub tor mkstate { php: i64, pmana: i64, bhp: i64, bdmg: i64 } -> i64

mkstate = setf(s: 0, sh: 0, w: 10, val: php): s1
|> setf(s: s1, sh: 10, w: 13, val: pmana): s2
|> setf(s: s2, sh: 23, w: 9, val: bhp): s3
|> setf(s: s3, sh: 32, w: 6, val: bdmg): s4
|> if(s4 >= 0)
    | then -> s4
    | else -> s4

// ---- spell tables ---------------------------------------------------------

pub tor costof { code: i64 } -> i64

costof = if(code == 1)
| then -> 53
| else |> if(code == 2)
    | then -> 73
    | else |> if(code == 3)
        | then -> 113
        | else |> if(code == 4)
            | then -> 173
            | else -> 229

pub tor tkof { code: i64 } -> i64

tkof = if(code == 3)
| then -> 1
| else |> if(code == 4)
    | then -> 2
    | else |> if(code == 5)
        | then -> 3
        | else -> 0

pub tor dmgof { code: i64 } -> i64

dmgof = if(code == 1)
| then -> 4
| else |> if(code == 2)
    | then -> 2
    | else -> 0

pub tor healof { code: i64 } -> i64

healof = if(code == 2)
| then -> 2
| else -> 0

// ---- packed-key codec -----------------------------------------------------

pub tor d47 { key: i64 } -> i64

d47 = if(key >= 0)
| then -> @divTrunc(key, 140737488355328)
| else -> @divTrunc(key, 140737488355328)

pub tor m47 { key: i64 } -> i64

m47 = if(key >= 0)
| then -> @mod(key, 140737488355328)
| else -> @mod(key, 140737488355328)

// ---- turn transitions (search variants: no si/over fields) ----------------

// one effects tick: poison damage, recharge mana, shield timer--
pub tor tick { s: i64 } -> i64

tick = gf(s, sh: 38, w: 3): pt
|> gf(s, sh: 44, w: 3): rt
|> gf(s, sh: 41, w: 3): st
|> gf(s, sh: 23, w: 9): bh
|> gf(s, sh: 10, w: 13): pm
|> if(pt > 0)
    | then
        |> setf(s, sh: 23, w: 9, val: @max(0, bh - 3)): s1
        |> setf(s: s1, sh: 38, w: 3, val: pt - 1): s2
        |> setf(s: s2, sh: 44, w: 3, val: rt - @as(i64, @intFromBool(rt > 0))): s3
        |> setf(s: s3, sh: 41, w: 3, val: st - @as(i64, @intFromBool(st > 0))): s4
        |> setf(s: s4, sh: 10, w: 13, val: pm + 101 * @as(i64, @intFromBool(rt > 0))): s5
        |> if(s5 >= 0)
            | then -> s5
            | else -> s5
    | else
        |> setf(s, sh: 38, w: 3, val: pt): s1
        |> setf(s: s1, sh: 44, w: 3, val: rt - @as(i64, @intFromBool(rt > 0))): s2
        |> setf(s: s2, sh: 41, w: 3, val: st - @as(i64, @intFromBool(st > 0))): s3
        |> setf(s: s3, sh: 10, w: 13, val: pm + 101 * @as(i64, @intFromBool(rt > 0))): s4
        |> if(s4 >= 0)
            | then -> s4
            | else -> s4

// cast spell `code` from a prepared state: pay cost, damage/heal, timer
pub tor cast2 { s: i64, code: i64 } -> i64

cast2 = gf(s, sh: 10, w: 13): pm
|> gf(s, sh: 23, w: 9): bh
|> gf(s, sh: 0, w: 10): ph
|> gf(s, sh: 38, w: 3): pt
|> gf(s, sh: 41, w: 3): st
|> gf(s, sh: 44, w: 3): rt
|> costof(code): cst
|> dmgof(code): dd
|> healof(code): hl
|> tkof(code): tk
|> setf(s, sh: 10, w: 13, val: pm - cst): s1
|> setf(s: s1, sh: 23, w: 9, val: @max(0, bh - dd)): s2
|> setf(s: s2, sh: 0, w: 10, val: ph + hl): s3
|> setf(s: s3, sh: 41, w: 3, val: st + (6 - st) * @as(i64, @intFromBool(tk == 1))): s4
|> setf(s: s4, sh: 38, w: 3, val: pt + (6 - pt) * @as(i64, @intFromBool(tk == 2))): s5
|> setf(s: s5, sh: 44, w: 3, val: rt + (5 - rt) * @as(i64, @intFromBool(tk == 3))): s6
|> if(s6 >= 0)
    | then -> s6
    | else -> s6

// boss attack: max(1, bdmg - armor); armor = 7 while shield timer > 0
pub tor attack2 { s: i64 } -> i64

attack2 = gf(s, sh: 41, w: 3): st
|> gf(s, sh: 32, w: 6): bd
|> gf(s, sh: 0, w: 10): ph
|> setf(s, sh: 0, w: 10, val: @max(0, ph - @max(1, bd - 7 * @as(i64, @intFromBool(st > 0))))): s1
|> if(s1 >= 0)
    | then -> s1
    | else -> s1

// player-turn start, once per pop: tick, boss-dead passthrough, hard drain.
// returns -1 when the hard-mode drain kills the branch (hp == 1).
pub tor prep { s: i64 } -> i64

prep = tick(s): s1
|> gf(s: s1, sh: 23, w: 9): bh
|> if(bh <= 0)
    | then -> s1
    | else
        |> gf(s: s1, sh: 0, w: 10): ph
        |> if(ph <= 1)
            | then -> 0 - 1
            | else
                |> setf(s: s1, sh: 0, w: 10, val: ph - 1): s2
                |> if(s2 >= 0)
                    | then -> s2
                    | else -> s2

// one spell attempt from a prepared (drained) state; -1 = dead end
pub tor casttry { s: i64, code: i64 } -> i64

casttry = gf(s, sh: 10, w: 13): pm
|> costof(code): cst
|> if(pm < cst)
    | then -> 0 - 1
    | else
        |> cast2(s, code): s2
        |> gf(s: s2, sh: 23, w: 9): bh2
        |> if(bh2 <= 0)
            | then -> s2
            | else
                |> tick(s: s2): s3
                |> gf(s: s3, sh: 23, w: 9): bh3
                |> if(bh3 <= 0)
                    | then -> s3
                    | else
                        |> attack2(s: s3): s4
                        |> gf(s: s4, sh: 0, w: 10): ph4
                        |> if(ph4 <= 0)
                            | then -> 0 - 1
                            | else -> s4

// dist update + heap push when `cost` improves on dist[state]; 1 pushed, 0 kept
pub tor tryupdate { hp: *std/heap:Heap_i64<heap>, dm: *std/map:Map_i64_i64<map>, state: i64, cost: i64 } -> i64

tryupdate = std/map:get(m: dm, k: state)
| value dv
    |> if(dv <= cost)
        | then -> 0
        | else
            |> std/map:set(m: dm, k: state, v: cost): _
                |> std/heap:push-i64(xs: hp, key: cost * 140737488355328 + state): _
                    |> if(1 >= 0)
                        | then -> 1
                        | else -> 1
| missing
    |> std/map:set(m: dm, k: state, v: cost): _
        |> std/heap:push-i64(xs: hp, key: cost * 140737488355328 + state): _
            |> if(1 >= 0)
                | then -> 1
                | else -> 1

// one popped state's expansion: prep once, then up to 5 spell successors.
// collections arrive as borrow params — the user-tor borrow path (660_038).
pub tor expandstate { hp: *std/heap:Heap_i64<heap>, dm: *std/map:Map_i64_i64<map>, state: i64, spent: i64 } -> i64

expandstate = prep(s: state): base
|> if(base < 0)
    | then -> 0
    | else
        |> gf(s: base, sh: 23, w: 9): bb
            |> if(bb <= 0)
                | then
                    |> tryupdate(hp, dm, state: base, cost: spent): r1
                        |> if(r1 >= 0)
                            | then -> 1
                            | else -> 1
                | else
                    |> for(0..5)
                        ! each c
                            |> casttry(s: base, code: @as(i64, @intCast(c + 1))): succ
                                |> if(succ >= 0)
                                    | then
                                        |> costof(code: @as(i64, @intCast(c + 1))): cc
                                            |> tryupdate(hp, dm, state: succ, cost: spent + cc): _
                        | done
                            |> if(1 >= 0)
                                | then -> 1
                                | else -> 1

// ---- driver ---------------------------------------------------------------

capture { bh: 0[i64], bd: 0[i64] }
! as pc
    |> std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_222_day22_part2/input.txt")
        ! line l
            |> std/regex:match(l)
                | `Hit Points: (?<h>[0-9]+)` { h }
                    |> std/string:parse-int(s: h)
                        | ok v
                            |> captured { bh: v }
                        | err _
                            |> captured { bh: 0 }
                | `Damage: (?<d>[0-9]+)` { d }
                    |> std/string:parse-int(s: d)
                        | ok v
                            |> captured { bd: v }
                        | err _
                            |> captured { bd: 0 }
        | done _
            |> std/heap:new-i64()
                | list hp
                    |> std/map:new()
                        | map dm
                            |> mkstate(php: 50, pmana: 500, bhp: pc.bh, bdmg: pc.bd): s0
                                |> tryupdate(hp, dm, state: s0, cost: 0): _
                                    |> capture { found: 0[i64], steps: 0[i64] }
                                        ! as sr |> for(0..1000000)
                                            ! each _
                                                |> std/heap:len-i64(xs: hp): hl
                                                    |> if(hl == 0 or sr.found > 0)
                                                        | then
                                                            |> captured { steps: sr.steps + 1 }
                                                        | else
                                                            |> std/heap:pop-i64(xs: hp)
                                                                | item key
                                                                    |> d47(key): spent
                                                                        |> m47(key): state
                                                                            |> gf(s: state, sh: 23, w: 9): bhp0
                                                                                |> if(bhp0 <= 0)
                                                                                    | then
                                                                                        |> captured { found: spent, steps: sr.steps + 1 }
                                                                                    | else
                                                                                        |> std/map:get(m: dm, k: state)
                                                                                            | value dv
                                                                                                |> if(dv < spent)
                                                                                                    | then
                                                                                                        |> captured { steps: sr.steps + 1 }
                                                                                                    | else
                                                                                                        |> expandstate(hp, dm, state, spent): _
                                                                                                            |> captured { steps: sr.steps + 1 }
                                                                                            | missing
                                                                                                |> captured { steps: sr.steps + 1 }
                                                                | empty
                                                                    |> captured { steps: sr.steps + 1 }
                                    | captured sres
                                        |> std/io:print.ln("{{ sres.found:d }}")
                                        |> std/map:free(m: dm)
                                            |> std/heap:free-i64(xs: hp)
                        | err e2
                            |> std/io:print.ln("ERR2 {{ e2:s }}")
                            |> std/heap:free-i64(xs: hp)
                | err e
                    |> std/io:print.ln("ERR {{ e:s }}")
        | failed e
            |> std/io:print.ln("FAILED {{ e:s }}")
| captured _
