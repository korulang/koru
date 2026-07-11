// REGRESSION GUARD (was the root-cause repro; FIXED) — ROOT CAUSE: a nested effect (read-lines) loses its output when it is
// nested under an OBLIGATION-CARRYING branch. The obligation/auto-discharge
// machinery and nested-effect lowering don't compose.
//
// Isolated by contrast (all else equal — read-lines nested in a branch body):
//   - under a SCALAR branch (args:count → `| count _`):  prints "done"  ✓
//   - under String<view!>  (from-page → `| ok s`):       NO output      ✗ (here)
//   - under List<list!>    (list:new  → `| list xs`):     NO output      ✗ (660_015)
//
// So it is neither read-lines-specific nor list-specific: the discriminator is
// the cleanup obligation on the branch binding. This is the shared root behind
// the recurring "works in some contexts, not all" effect/obligation failures
// (cf. 660_013 for-loop auto-discharge, the capture-at-flow-level gap). Goes
// green when a nested effect lowers identically regardless of the obligation on
// the enclosing branch binding.
import std/io
import std/fs
import std/string

std/string:from-page(text: "x")
| ok s |> std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_171_day17_part1/input.txt")
    ! line _ |> _
    | done _ |> std/io:print.ln("done") |> std/string:free(s)
    | failed _ |> std/io:print.ln("failed") |> std/string:free(s)
| err _ |> std/io:print.ln("err")
