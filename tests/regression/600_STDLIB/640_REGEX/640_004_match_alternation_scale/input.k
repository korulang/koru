// GREEN PIN (was RED; found by AoC day 5 part 2): the match pipeline had a
// SCALE ceiling on alternations — nine 2-char alternation branches with
// [a-z]* filler tripped error.BufferOverflow at emission. Root cause: the
// emission CodeEmitter wrote into a FIXED 256KB buffer (koru_std/compiler.kz);
// a big-alternation DFA alone passes that. Fixed 2026-06-12: CodeEmitter
// grows on demand (initGrowable), so generated code has no size ceiling.
// The 676-branch finite-alphabet encoding of (..).*\1 still exceeds the
// engine's deliberate state cap (max_dfa_states, regex_engine.zig) — but
// that failure is now LOUD and NAMED: "regex: cannot compile pattern
// `...`: DfaTooLarge" at the match site (it used to surface as a bogus
// KORU100 blaming a binding; fixed in koru_std/regex.kz the same day).
// Day 5p2's pure form waits on an engine strategy for huge alternations
// (lazy DFA / NFA simulation), tracked in FRONTIERS.

import std/io
import std/regex

std/regex:match("abab")
| `[a-z]*(aa[a-z]*aa|ab[a-z]*ab|ax[a-z]*ax|ba[a-z]*ba|bb[a-z]*bb|bx[a-z]*bx|xa[a-z]*xa|xb[a-z]*xb|xx[a-z]*xx)[a-z]*` _ |> std/io:print.ln("yes")
| no-match |> std/io:print.ln("no")
