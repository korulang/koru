// AoC 2015 Day 5 Part 1 — "Doesn't He Have Intern-Elves For This?"
// (5 statement examples; 2 are nice.) PURE .k — and the ledger is BORN
// EMPTY: every construct this day needs is already a stdlib citizen.
// The three niceness rules are three regex dispatches (compile-time DFAs):
//   1. ≥3 vowels        — full-match with three [aeiou] islands
//   2. a double letter  — the classic (.)\1 is NOT regular-engine food, but
//                         over a finite alphabet it IS regular: 26-way
//                         alternation (aa|bb|...|zz). Plain (...) is
//                         non-capturing structure (named groups capture).
//   3. no ab/cd/pq/xy   — match = naughty, so the NICE path is | no-match
// nice = rule1 AND rule2 AND NOT rule3 — spelled as nested dispatch where
// each rule's pass-arm runs the next rule and rule 3's no-match increments.

import std/io
import std/control
import std/regex

// (single-line block: multi-line const{} with nested braces is a known
// collector gap — see FRONTIERS tensions)
const { samples: &[_][]const u8{ "ugknbfddgicrmopn", "aaa", "jchzalrnumimnmhp", "haegwjzuvuyypxyu", "dvszwmarrgswjxmb" } }

capture { nice: 0[i64] }
! as acc |> for(samples)
    ! each s |> std/regex:match(s)
        | `[a-z]*[aeiou][a-z]*[aeiou][a-z]*[aeiou][a-z]*` _ |> std/regex:match(s)
            | `[a-z]*(aa|bb|cc|dd|ee|ff|gg|hh|ii|jj|kk|ll|mm|nn|oo|pp|qq|rr|ss|tt|uu|vv|ww|xx|yy|zz)[a-z]*` _ |> std/regex:match(s)
                | `[a-z]*(ab|cd|pq|xy)[a-z]*` _ |> _
                | no-match |> captured { nice: acc.nice + 1 }
            | no-match |> _
        | no-match |> _
| captured total |> std/io:print.ln("{{ total.nice:d }}")
