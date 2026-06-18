// PIN (failing): a for-loop variable used inside a sufficiently COMPLEX value
// expression of a capture-array write is wrongly flagged KORU100 'unused'. The
// `for` template renames the loop var to __koru_item (and extracts complex/
// nested bodies into a __koru_inline_scoped_N function), so KORU100's usage scan
// — which looks for the ORIGINAL name in the post-expansion node — can't find it.
// Simple write values keep the var findable and pass; the dense conway-style
// expression below does not. Surfaced building AoC day18 (Conway).
// Expected: compiles and prints "ok" (the computed grid is irrelevant to the pin
// — the assertion is that valid code is not rejected).
import std/io

pub event step { g: [4][4]i64 }
| next [4][4]i64
step = capture { h: [4][4]i64{ .{ 0, 0, 0, 0 }, .{ 0, 0, 0, 0 }, .{ 0, 0, 0, 0 }, .{ 0, 0, 0, 0 } } }
! as a |> for(1..3)
    ! each r |> for(1..3)
        ! each c |> captured { h[r][c]: @as(i64, @intFromBool((g[r][c] == 1 and ((g[r - 1][c - 1] + g[r - 1][c] + g[r - 1][c + 1] + g[r][c - 1] + g[r][c + 1] + g[r + 1][c - 1] + g[r + 1][c] + g[r + 1][c + 1]) == 2 or (g[r - 1][c - 1] + g[r - 1][c] + g[r - 1][c + 1] + g[r][c - 1] + g[r][c + 1] + g[r + 1][c - 1] + g[r + 1][c] + g[r + 1][c + 1]) == 3)) or (g[r][c] == 0 and (g[r - 1][c - 1] + g[r - 1][c] + g[r - 1][c + 1] + g[r][c - 1] + g[r][c + 1] + g[r + 1][c - 1] + g[r + 1][c] + g[r + 1][c + 1]) == 3)) }
      | done |> _
  | done |> _
| captured result => next result.h
step(g: [4][4]i64{ .{ 1, 1, 1, 1 }, .{ 1, 1, 1, 1 }, .{ 1, 1, 1, 1 }, .{ 1, 1, 1, 1 } })
| next _ |> std/io:print.ln("ok")
