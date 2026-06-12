// RED ACCEPTANCE PIN — four-level nesting (Lars: "four levels even — even
// IF four and two are the same"):
//   L1 outer capture cell { total, files }
//   L2 outer read-lines ! line handler (writes the OUTER cell)
//   L3 count-file SUBFLOW with its OWN cell
//   L4 inner read-lines ! line handler (writes the INNER cell)
// Goes green when effect lowering matches the effect-branch design: fully
// INLINED, MONOMORPHIZED code (Lars-ratified direction 2026-06-12) — one
// flat frame where both cells are ordinary locals, NOT callbacks across a
// namespace boundary, NOT a threadlocal side channel (a spine that greened
// this was built and REVERTED: it band-aided the control inversion).
// a.data has 2 lines, b.data has 3 → "2 files, 5 lines".

import std/io
import std/fs

pub event count-file { path: []const u8 }
| counted i64

count-file = capture { n: 0[i64] }
! as inner |> std/fs:read-lines(path)
    ! line _ |> captured { n: inner.n + 1 }
    | done _ |> _
    | failed _ |> _
| captured r => counted r.n

capture { total: 0[i64], files: 0[i64] }
! as acc |> std/fs:read-lines(path: "tests/regression/600_STDLIB/620_FS/620_005_cell_ctx_deep_nesting/input.txt")
    ! line f |> count-file(path: f)
        | counted n |> captured { total: acc.total + n, files: acc.files + 1 }
    | done _ |> _
    | failed e |> std/io:print.ln("FAILED {{ e:s }}")
| captured t |> std/io:print.ln("{{ t.files:d }} files, {{ t.total:d }} lines")
