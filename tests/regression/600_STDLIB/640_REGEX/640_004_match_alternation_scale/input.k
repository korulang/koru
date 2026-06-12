// RED PIN (found by AoC day 5 part 2): the match pipeline has a SCALE
// ceiling on alternations. Nine 2-char alternation branches with [a-z]*
// filler already trips error.BufferOverflow at emission; the 676-branch
// finite-alphabet encoding of (..).*\1 fails earlier and surfaces as a
// bogus KORU100 (a compileError replacement confusing the checker — the
// failure should be LOUD and say "pattern too large", not blame a binding).
// Goes green when the engine/emission handles big-alternation DFAs (or
// rejects them with a real diagnostic and this pin's pattern shrinks to
// just under the documented cap).

import std/io
import std/regex

std/regex:match("abab")
| `[a-z]*(aa[a-z]*aa|ab[a-z]*ab|ax[a-z]*ax|ba[a-z]*ba|bb[a-z]*bb|bx[a-z]*bx|xa[a-z]*xa|xb[a-z]*xb|xx[a-z]*xx)[a-z]*` _ |> std/io:print.ln("yes")
| no-match |> std/io:print.ln("no")
