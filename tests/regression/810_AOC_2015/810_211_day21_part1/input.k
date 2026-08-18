// AoC 2015 Day 21 Part 1 — cheapest shop loadout that beats the boss.
// Boss stats are personal-only; this boss (104hp/8dmg/1armor) is
// CONSTRUCTED and python-oracled (cheapest win 78; the statement's demo
// boss 12/7/2 is degenerate — a bare dagger wins). Fight math is the
// statement's (ceil-turns comparison). Boss parse is Koru's (named groups,
// typed destructure). The loadout SEARCH is now Koru's too: a finite nested
// capture-fold over the FIXED item tables (weapons/armor/rings are puzzle
// spec, encoded as branchless inline @intFromBool tables — same shape as
// day15's flat-table store and day17's nested subset sweep). Loadout indices:
// weapon w(0..4), armor a(0=none..5), rings r1/r2 (0=none, 1..3 damage,
// 4..6 defense); valid iff r2==0 or (r1>=1 and r2>r1). win = ceil(bh/pe) <=
// ceil(100/be). Non-winning/invalid loadouts contribute a BIG sentinel so
// @min ignores them.

import std/io
import std/fs
import std/regex

pub tor shop { bh: i64, bd: i64, ba: i64, want-loss: i64 } -> i64

shop = capture { best: 9999999[i64] }
! as acc |> for(0..5)
    ! each w |> for(0..6)
        ! each a |> for(0..7)
            ! each r1 |> for(0..7)
                ! each r2 |> captured { best: @min(acc.best, (((8*@as(i64,@intFromBool(w==0))+10*@as(i64,@intFromBool(w==1))+25*@as(i64,@intFromBool(w==2))+40*@as(i64,@intFromBool(w==3))+74*@as(i64,@intFromBool(w==4)))+(13*@as(i64,@intFromBool(a==1))+31*@as(i64,@intFromBool(a==2))+53*@as(i64,@intFromBool(a==3))+75*@as(i64,@intFromBool(a==4))+102*@as(i64,@intFromBool(a==5)))+(25*@as(i64,@intFromBool(r1==1))+50*@as(i64,@intFromBool(r1==2))+100*@as(i64,@intFromBool(r1==3))+20*@as(i64,@intFromBool(r1==4))+40*@as(i64,@intFromBool(r1==5))+80*@as(i64,@intFromBool(r1==6)))+(25*@as(i64,@intFromBool(r2==1))+50*@as(i64,@intFromBool(r2==2))+100*@as(i64,@intFromBool(r2==3))+20*@as(i64,@intFromBool(r2==4))+40*@as(i64,@intFromBool(r2==5))+80*@as(i64,@intFromBool(r2==6))))*(@as(i64,@intFromBool(@divFloor(bh+@max(@as(i64,1),((4*@as(i64,@intFromBool(w==0))+5*@as(i64,@intFromBool(w==1))+6*@as(i64,@intFromBool(w==2))+7*@as(i64,@intFromBool(w==3))+8*@as(i64,@intFromBool(w==4)))+(1*@as(i64,@intFromBool(r1==1))+2*@as(i64,@intFromBool(r1==2))+3*@as(i64,@intFromBool(r1==3)))+(1*@as(i64,@intFromBool(r2==1))+2*@as(i64,@intFromBool(r2==2))+3*@as(i64,@intFromBool(r2==3))))-ba)-1,@max(@as(i64,1),((4*@as(i64,@intFromBool(w==0))+5*@as(i64,@intFromBool(w==1))+6*@as(i64,@intFromBool(w==2))+7*@as(i64,@intFromBool(w==3))+8*@as(i64,@intFromBool(w==4)))+(1*@as(i64,@intFromBool(r1==1))+2*@as(i64,@intFromBool(r1==2))+3*@as(i64,@intFromBool(r1==3)))+(1*@as(i64,@intFromBool(r2==1))+2*@as(i64,@intFromBool(r2==2))+3*@as(i64,@intFromBool(r2==3))))-ba))<=@divFloor(@as(i64,100)+@max(@as(i64,1),bd-((1*@as(i64,@intFromBool(a==1))+2*@as(i64,@intFromBool(a==2))+3*@as(i64,@intFromBool(a==3))+4*@as(i64,@intFromBool(a==4))+5*@as(i64,@intFromBool(a==5)))+(1*@as(i64,@intFromBool(r1==4))+2*@as(i64,@intFromBool(r1==5))+3*@as(i64,@intFromBool(r1==6)))+(1*@as(i64,@intFromBool(r2==4))+2*@as(i64,@intFromBool(r2==5))+3*@as(i64,@intFromBool(r2==6)))))-1,@max(@as(i64,1),bd-((1*@as(i64,@intFromBool(a==1))+2*@as(i64,@intFromBool(a==2))+3*@as(i64,@intFromBool(a==3))+4*@as(i64,@intFromBool(a==4))+5*@as(i64,@intFromBool(a==5)))+(1*@as(i64,@intFromBool(r1==4))+2*@as(i64,@intFromBool(r1==5))+3*@as(i64,@intFromBool(r1==6)))+(1*@as(i64,@intFromBool(r2==4))+2*@as(i64,@intFromBool(r2==5))+3*@as(i64,@intFromBool(r2==6))))))))*@as(i64,@intFromBool((r2==0) or ((r1>=1) and (r2>r1)))))+9999999*(1-(@as(i64,@intFromBool(@divFloor(bh+@max(@as(i64,1),((4*@as(i64,@intFromBool(w==0))+5*@as(i64,@intFromBool(w==1))+6*@as(i64,@intFromBool(w==2))+7*@as(i64,@intFromBool(w==3))+8*@as(i64,@intFromBool(w==4)))+(1*@as(i64,@intFromBool(r1==1))+2*@as(i64,@intFromBool(r1==2))+3*@as(i64,@intFromBool(r1==3)))+(1*@as(i64,@intFromBool(r2==1))+2*@as(i64,@intFromBool(r2==2))+3*@as(i64,@intFromBool(r2==3))))-ba)-1,@max(@as(i64,1),((4*@as(i64,@intFromBool(w==0))+5*@as(i64,@intFromBool(w==1))+6*@as(i64,@intFromBool(w==2))+7*@as(i64,@intFromBool(w==3))+8*@as(i64,@intFromBool(w==4)))+(1*@as(i64,@intFromBool(r1==1))+2*@as(i64,@intFromBool(r1==2))+3*@as(i64,@intFromBool(r1==3)))+(1*@as(i64,@intFromBool(r2==1))+2*@as(i64,@intFromBool(r2==2))+3*@as(i64,@intFromBool(r2==3))))-ba))<=@divFloor(@as(i64,100)+@max(@as(i64,1),bd-((1*@as(i64,@intFromBool(a==1))+2*@as(i64,@intFromBool(a==2))+3*@as(i64,@intFromBool(a==3))+4*@as(i64,@intFromBool(a==4))+5*@as(i64,@intFromBool(a==5)))+(1*@as(i64,@intFromBool(r1==4))+2*@as(i64,@intFromBool(r1==5))+3*@as(i64,@intFromBool(r1==6)))+(1*@as(i64,@intFromBool(r2==4))+2*@as(i64,@intFromBool(r2==5))+3*@as(i64,@intFromBool(r2==6)))))-1,@max(@as(i64,1),bd-((1*@as(i64,@intFromBool(a==1))+2*@as(i64,@intFromBool(a==2))+3*@as(i64,@intFromBool(a==3))+4*@as(i64,@intFromBool(a==4))+5*@as(i64,@intFromBool(a==5)))+(1*@as(i64,@intFromBool(r1==4))+2*@as(i64,@intFromBool(r1==5))+3*@as(i64,@intFromBool(r1==6)))+(1*@as(i64,@intFromBool(r2==4))+2*@as(i64,@intFromBool(r2==5))+3*@as(i64,@intFromBool(r2==6))))))))*@as(i64,@intFromBool((r2==0) or ((r1>=1) and (r2>r1)))))))) }
            | done |> _
        | done |> _
    | done |> _
| done |> _
| captured r -> r.best

std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_211_day21_part1/input.txt")
! line l |> std/regex:match(l)
    | `(?<bh>[0-9]+) (?<bd>[0-9]+) (?<ba>[0-9]+)` { bh: i64, bd: i64, ba: i64 } |> shop(bh, bd, ba, want-loss: 0): g |> std/io:print.ln("{{ g:d }}")
    | no-match |> std/io:print.ln("BAD LINE {{ l:s }}")
| done _ |> _
| failed e |> std/io:print.ln("FAILED {{ e:s }}")
