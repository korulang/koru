// AoC 2015 Day 5 Part 2 — new niceness: (1) a two-letter pair appears
// twice without overlap (xyxy), (2) a letter repeats with one between
// (xyx). qjhvhtzxzqqjkmpb + xxyxx nice; the other two naughty → 2.
//
// GREEN (was RED since the pure-Koru migration deleted its host leaves).
// The old ledger blamed the regex route ((..).*\1 as 676 alternations →
// DfaTooLarge), but the pristine spelling never needed regex. ONE
// left-to-right recursive walk keeps TWO string-masks — char → position
// bitmask, 2-char-window → position bitmask — and tests each new start
// against its mask BEFORE recording it:
//   • sandwich — s[i]==s[i+2] iff the current char's mask holds the bit
//     for i−2. Starts are stored shifted +2, so that bit parks exactly
//     at `(oc >> i) & 1`.
//   • pair — some earlier window starts ≥ 2 behind iff the window mask
//     has any bit ≤ i, i.e. `ow & ((1 << (i+1)) - 1) ≠ 0`, same shift.
// Every step chains through event arms; substring's own err arm is the
// loop terminator. No capture cells, no post-template pipelines. The
// masks are plain std/string-map handles passed as qualified
// `<std/string-map:map>` borrows — 660_027's ruled spelling. Masks are
// i64s, so the pin covers the statement scale (lines well under 60
// chars), matching how day 11 pins its fixed 8-letter alphabet. The
// FRONTIERS entry on huge-alternation regex strategy stays open for any
// day that truly needs it — this one never did.

import std/io
import std/fs
import std/string
import std/string-map
import std/fmt

// Map lookup defaulting to 0.
pub tor get0 { m: *Map_string_i64<std/string-map:map>, k: string } -> i64

get0 = std/string-map:get(m, k)
| value v -> v
| missing -> 0

// Test position i against both rules; record it; advance or report nice.
pub tor walk { h: *String<std/string:instance>, cm: *Map_string_i64<std/string-map:map>, wm: *Map_string_i64<std/string-map:map>, i: usize, sand: i64, pair: i64 } -> i64

walk = std/string:substring(s: h, start: i, end: i + 1)
| ok c |> std/fmt:ln("{{ c:S }}"): key
    |> get0(m: cm, k: key.text): oc
    |> std/string-map:set(m: cm, k: key.text, v: oc | (@as(i64, 1) << @as(u6, @intCast(i + 2))))
    |> std/string:free(s: c)
    |> std/string:substring(s: h, start: i, end: i + 2)
        | ok w |> std/fmt:ln("{{ w:S }}"): key2
            |> get0(m: wm, k: key2.text): ow
            |> std/string-map:set(m: wm, k: key2.text, v: ow | (@as(i64, 1) << @as(u6, @intCast(i + 2))))
            |> std/string:free(s: w)
            |> decide(h, cm, wm, i, oc, ow, sand, pair): d -> d
        | err _ -> 0
| err _ -> 0

// The fork: sandwich bit parked at i? any non-overlapping earlier window?
// Otherwise advance to the next start.
pub tor decide { h: *String<std/string:instance>, cm: *Map_string_i64<std/string-map:map>, wm: *Map_string_i64<std/string-map:map>, i: usize, oc: i64, ow: i64, sand: i64, pair: i64 } -> i64

decide = if((oc >> @as(u6, @intCast(i))) & 1 == 1)
| then |> decide-pair(h, cm, wm, i, ow, sand: 1, pair): d -> d
| else |> decide-pair(h, cm, wm, i, ow, sand, pair): d -> d

pub tor decide-pair { h: *String<std/string:instance>, cm: *Map_string_i64<std/string-map:map>, wm: *Map_string_i64<std/string-map:map>, i: usize, ow: i64, sand: i64, pair: i64 } -> i64

decide-pair = if((ow & ((@as(i64, 1) << @as(u6, @intCast(i + 1))) - 1)) > 0)
| then |> decide-done(h, cm, wm, i, sand, pair: 1): d -> d
| else |> decide-done(h, cm, wm, i, sand, pair): d -> d

pub tor decide-done { h: *String<std/string:instance>, cm: *Map_string_i64<std/string-map:map>, wm: *Map_string_i64<std/string-map:map>, i: usize, sand: i64, pair: i64 } -> i64

decide-done = if(sand > 0 and pair > 0)
| then -> 1
| else |> walk(h, cm, wm, i: i + 1, sand, pair): t -> t

capture { nice: 0[i64] }
! as acc |> std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_052_day05_part2/input.txt")
    ! line l |> std/string-map:new()
        | map cm |> std/string-map:new()
            | map wm |> std/string:from-page(text: l)
                | ok hv |> std/string:take(s: hv): hh
                    |> walk(h: hh, cm, wm, i: 0, sand: 0, pair: 0): r
                        |> std/string-map:free(m: wm)
                        |> std/string-map:free(m: cm)
                        |> std/string:free(s: hh)
                        |> captured { nice: acc.nice + r }
            | err _ |> _
        | err _ |> _
    | done _ |> _
    | failed e |> std/io:print.ln("FAILED {{ e:s }}")
| captured total |> std/io:print.ln("{{ total.nice:d }}")
