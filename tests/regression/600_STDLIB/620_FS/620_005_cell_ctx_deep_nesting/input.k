// ACCEPTANCE PIN — GREEN under effect inlining. Four-level nesting (Lars:
// "four levels even — even IF four and two are the same"):
//   L1 outer capture cell { total, files }
//   L2 outer read-lines ! line handler (writes the OUTER cell)
//   L3 count-file SUBFLOW with its OWN cell
//   L4 inner read-lines ! line handler (writes the INNER cell)
// Both cells are ordinary locals in their own frames (the inner subflow is
// its own function — value-coupled, contract = compilation boundary); the
// effect splices share scope by construction. Fully inlined, monomorphized.
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
