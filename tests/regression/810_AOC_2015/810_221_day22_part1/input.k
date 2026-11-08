// AoC 2015 Day 22 Part 1 — the two SCRIPTED statement fights, replayed
// exactly (fight 1: Poison, Magic Missile vs 13hp/8dmg -> win hp=2 mana=24;
// fight 2: Recharge,Shield,Drain,Poison,Magic Missile vs 14/8 -> win
// hp=1 mana=114). Rules verified against the statement's turn narration
// (adventofcode.com/2015/day/22): effects tick at the start of BOTH the
// player's and the boss's turns (apply, then decrement; 0 ends it), the
// player casts one scripted spell per turn, the boss attacks for
// max(1, dmg - armor) where armor = 7 while Shield is active, first combatant
// at <= 0 hp loses, and an uncastable spell (script exhausted or mana short)
// loses. Boss armor is ignored entirely (magic damage).
//
// The parked header's KORU030 gap is real but routed around: no user tor
// takes a collection. The spell script is packed into an i64 as little-
// endian base-8 digits (3 bits per code, spells cast in index order), the
// whole fight state is ONE packed i64 threaded as a plain parameter through
// a value-recursive `fight` tor — no for/capture loop at all. (A for+capture
// version was tried first and exposed a second defect: capture-cell field
// reads inside call ARGUMENTS see the pre-loop snapshot while captured-expr
// reads see live values — pinned as scratch/aoc22/probe3 evidence; the
// recursion shape sidesteps it entirely.)
//
// Fight-state packing (i64, all fields non-negative, clamped at 0):
//   php   sh 0  w10   player hp        (statement: 10)
//   pmana sh10 w13   player mana       (statement: 250)
//   bhp   sh23 w9    boss hp
//   bdmg  sh32 w6    boss damage
//   pt    sh38 w3    poison timer      (6 turns, 3 dmg/tick)
//   st    sh41 w3    shield timer      (6 turns, +7 armor)
//   rt    sh44 w3    recharge timer    (5 turns, +101 mana/tick)
//   si    sh47 w5    next spell index
//   over  sh52 w2    0 running, 1 win, 2 lose
//
// Spell codes (base-8 digits): 1 missile(53,4) 2 drain(73,2,+2hp)
//   3 shield(113,t6) 4 poison(173,t6) 5 recharge(229,t5); 0 = exhausted pad
// Script packing: script = c0 + c1*8 + c2*64 + ...  (si indexes digits)

import std/io
import std/fs
import std/regex
import std/string

// ---- packed-state field access -------------------------------------------

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

// timer kind: 0 none, 1 shield(6), 2 poison(6), 3 recharge(5)
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

// script digit at index si: (script / 8^si) % 8 ; 8^si = 1 << (3*si)
pub tor codeat { script: i64, si: i64 } -> i64

codeat = if(si > 20)
| then -> 0
| else -> @mod(@divTrunc(script, @as(i64, 1) << @as(u6, @intCast(3 * si))), 8)

// ---- turn transitions -----------------------------------------------------

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

// cast spell `code`: pay cost, apply damage/heal, (re)start its timer, si+1
pub tor casted { s: i64, code: i64 } -> i64

casted = gf(s, sh: 10, w: 13): pm
|> gf(s, sh: 23, w: 9): bh
|> gf(s, sh: 0, w: 10): ph
|> gf(s, sh: 38, w: 3): pt
|> gf(s, sh: 41, w: 3): st
|> gf(s, sh: 44, w: 3): rt
|> gf(s, sh: 47, w: 5): si
|> costof(code): cst
|> dmgof(code): dd
|> healof(code): hl
|> tkof(code): tk
|> setf(s, sh: 10, w: 13, val: pm - cst): s1
|> setf(s: s1, sh: 23, w: 9, val: @max(0, bh - dd)): s2
|> setf(s: s2, sh: 0, w: 10, val: ph + hl): s3
|> setf(s: s3, sh: 47, w: 5, val: si + 1): s4
|> setf(s: s4, sh: 41, w: 3, val: st + (6 - st) * @as(i64, @intFromBool(tk == 1))): s5
|> setf(s: s5, sh: 38, w: 3, val: pt + (6 - pt) * @as(i64, @intFromBool(tk == 2))): s6
|> setf(s: s6, sh: 44, w: 3, val: rt + (5 - rt) * @as(i64, @intFromBool(tk == 3))): s7
|> if(s7 >= 0)
    | then -> s7
    | else -> s7

// boss attack: max(1, bdmg - armor); armor = 7 while shield timer > 0
pub tor attack { s: i64 } -> i64

attack = gf(s, sh: 41, w: 3): st
|> gf(s, sh: 32, w: 6): bd
|> gf(s, sh: 0, w: 10): ph
|> if(st > 0)
    | then
        |> if(bd - 7 < 1)
            | then
                |> setf(s, sh: 0, w: 10, val: @max(0, ph - 1)): s1
                |> setf(s: s1, sh: 52, w: 2, val: @as(i64, @intFromBool(ph - 1 <= 0))): s2
                |> if(s2 >= 0)
                    | then -> s2
                    | else -> s2
            | else
                |> setf(s, sh: 0, w: 10, val: @max(0, ph - (bd - 7))): s1
                |> setf(s: s1, sh: 52, w: 2, val: @as(i64, @intFromBool(ph - (bd - 7) <= 0))): s2
                |> if(s2 >= 0)
                    | then -> s2
                    | else -> s2
    | else
        |> if(bd < 1)
            | then
                |> setf(s, sh: 0, w: 10, val: @max(0, ph - 1)): s1
                |> setf(s: s1, sh: 52, w: 2, val: @as(i64, @intFromBool(ph - 1 <= 0))): s2
                |> if(s2 >= 0)
                    | then -> s2
                    | else -> s2
            | else
                |> setf(s, sh: 0, w: 10, val: @max(0, ph - bd)): s1
                |> setf(s: s1, sh: 52, w: 2, val: @as(i64, @intFromBool(ph - bd <= 0))): s2
                |> if(s2 >= 0)
                    | then -> s2
                    | else -> s2

// one full round: tick, cast-or-lose, tick, attack — with death checks
pub tor turnstep { s: i64, code: i64, ns: i64 } -> i64

turnstep = gf(s, sh: 52, w: 2): ov0
|> if(ov0 != 0)
    | then -> s
    | else
        |> tick(s): s1
        |> gf(s: s1, sh: 23, w: 9): b1
        |> if(b1 <= 0)
            | then
                |> setf(s: s1, sh: 52, w: 2, val: 1): r1
                |> if(r1 >= 0)
                    | then -> r1
                    | else -> r1
            | else
                |> gf(s: s1, sh: 47, w: 5): si1
                |> if(si1 >= ns)
                    | then
                        |> setf(s: s1, sh: 52, w: 2, val: 2): r2
                        |> if(r2 >= 0)
                            | then -> r2
                            | else -> r2
                    | else
                        |> costof(code): cst
                        |> gf(s: s1, sh: 10, w: 13): pm1
                        |> if(pm1 < cst)
                            | then
                                |> setf(s: s1, sh: 52, w: 2, val: 2): r3
                                |> if(r3 >= 0)
                                    | then -> r3
                                    | else -> r3
                            | else
                                |> casted(s: s1, code): s2
                                |> gf(s: s2, sh: 23, w: 9): b2
                                |> if(b2 <= 0)
                                    | then
                                        |> setf(s: s2, sh: 52, w: 2, val: 1): r4
                                        |> if(r4 >= 0)
                                            | then -> r4
                                            | else -> r4
                                    | else
                                        |> tick(s: s2): s3
                                        |> gf(s: s3, sh: 23, w: 9): b3
                                        |> if(b3 <= 0)
                                            | then
                                                |> setf(s: s3, sh: 52, w: 2, val: 1): r5
                                                |> if(r5 >= 0)
                                                    | then -> r5
                                                    | else -> r5
                                            | else
                                                |> attack(s: s3): s4
                                                |> if(s4 >= 0)
                                                    | then -> s4
                                                    | else -> s4

// value-recursive driver: one turnstep per round until over != 0
pub tor fight { s: i64, script: i64, ns: i64 } -> i64

fight = gf(s, sh: 52, w: 2): ov
|> if(ov != 0)
    | then -> s
    | else
        |> gf(s, sh: 47, w: 5): si
        |> codeat(script, si): cd
        |> turnstep(s, code: cd, ns): s1
        |> fight(s: s1, script, ns): r
        |> if(r >= 0)
            | then -> r
            | else -> r

// ---- driver ---------------------------------------------------------------
// per line: "<bhp> <bdmg> <spell...>" — first two pieces are boss stats,
// the rest are spell names packed little-endian base-8 into `sc`.

std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_221_day22_part1/input.txt")
! line l
    |> capture { i: 0[i64], bh: 0[i64], bd: 0[i64], sc: 0[i64] }
        ! as pc |> std/string:split(s: l, sep: " ")
            ! piece p
                |> if(pc.i < 2)
                    | then
                        |> std/string:parse-int(s: p)
                            | ok n
                                |> if(pc.i == 0)
                                    | then |> captured { i: pc.i + 1, bh: n }
                                    | else |> captured { i: pc.i + 1, bd: n }
                            | err _ |> std/io:print.ln("BAD num: {{ p:s }}") |> captured { i: pc.i + 1 }
                    | else
                        |> std/regex:match(p)
                            | `missile` _ |> captured { i: pc.i + 1, sc: pc.sc + 1 * (@as(i64, 1) << @as(u6, @intCast(3 * (pc.i - 2)))) }
                            | `drain` _ |> captured { i: pc.i + 1, sc: pc.sc + 2 * (@as(i64, 1) << @as(u6, @intCast(3 * (pc.i - 2)))) }
                            | `shield` _ |> captured { i: pc.i + 1, sc: pc.sc + 3 * (@as(i64, 1) << @as(u6, @intCast(3 * (pc.i - 2)))) }
                            | `poison` _ |> captured { i: pc.i + 1, sc: pc.sc + 4 * (@as(i64, 1) << @as(u6, @intCast(3 * (pc.i - 2)))) }
                            | `recharge` _ |> captured { i: pc.i + 1, sc: pc.sc + 5 * (@as(i64, 1) << @as(u6, @intCast(3 * (pc.i - 2)))) }
                            | no-match |> std/io:print.ln("BAD spell: {{ p:s }}") |> captured { i: pc.i + 1 }
            | done cnt
                |> mkstate(php: 10, pmana: 250, bhp: pc.bh, bdmg: pc.bd): s0
                    |> fight(s: s0, script: pc.sc, ns: pc.i - 2): fin
                    |> gf(s: fin, sh: 52, w: 2): ov
                    |> gf(s: fin, sh: 0, w: 10): fhp
                    |> gf(s: fin, sh: 10, w: 13): fmana
                    |> if(ov == 1)
                        | then |> std/io:print.ln("win hp={{ fhp:d }} mana={{ fmana:d }}")
                        | else |> std/io:print.ln("lose hp={{ fhp:d }} mana={{ fmana:d }}")
        | err e2 |> std/io:print.ln("ERR2 {{ e2:s }}")
| done _ |> _
| failed e3 |> std/io:print.ln("FAILED {{ e3:s }}")
