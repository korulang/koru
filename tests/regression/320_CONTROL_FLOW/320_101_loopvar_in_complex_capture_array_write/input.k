// PIN (failing): a sufficiently COMPLEX value expression in a capture-fold
// write. Surfaced building AoC day18 (Conway). Sum over the 2x2 interior of an
// all-1 4x4 grid where each cell's guard holds → should print 4. The IDENTICAL
// structure with a SIMPLE value prints correctly (cf. 320_099-era tests), so the
// trigger is expression complexity. This exercises TWO distinct bugs:
//   1. KORU100 false-positive on the loop var — FIXED (flow_checker: the `for`
//      template renames the loop var to __koru_item / hoists the body into
//      __koru_inline_scoped_N, so the unused-binding check now validates loop
//      vars in frontend on the intact `.foreach` and no longer re-checks them in
//      all-mode). Compiles cleanly now.
//   2. EMISSION emits EMPTY — STILL OPEN. The program compiles and runs (exit 0)
//      but produces NO output; the simple-value version of the same structure
//      prints. Likely kin to the noted "if-emits-empty in deep nesting" gap.
//      day18 stays red on this. Green when emission no longer drops complex
//      capture-fold values.
import std/io

capture { total: 0[i64], g: [4][4]i64{ .{ 1, 1, 1, 1 }, .{ 1, 1, 1, 1 }, .{ 1, 1, 1, 1 }, .{ 1, 1, 1, 1 } } }
! as a |> for(1..3)
    ! each r |> for(1..3)
        ! each c |> captured { total: a.total + @as(i64, @intFromBool((a.g[r][c] == 1 and ((a.g[r - 1][c - 1] + a.g[r - 1][c] + a.g[r - 1][c + 1] + a.g[r][c - 1] + a.g[r][c + 1] + a.g[r + 1][c - 1] + a.g[r + 1][c] + a.g[r + 1][c + 1]) >= 1 or (a.g[r - 1][c - 1] + a.g[r - 1][c] + a.g[r - 1][c + 1] + a.g[r][c - 1] + a.g[r][c + 1] + a.g[r + 1][c - 1] + a.g[r + 1][c] + a.g[r + 1][c + 1]) == 99)) or (a.g[r][c] == 0 and (a.g[r - 1][c - 1] + a.g[r - 1][c] + a.g[r - 1][c + 1] + a.g[r][c - 1] + a.g[r][c + 1] + a.g[r + 1][c - 1] + a.g[r + 1][c] + a.g[r + 1][c + 1]) == 99)) }
      | done |> _
  | done |> _
| captured res |> std/io:print.ln("{{ res.total:d }}")
