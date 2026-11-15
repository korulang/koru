// Sequential for-phases under one capture: both loops fold into the same
// shared mutable array, and the capture's `| captured` arm runs after both.
//
// The second loop is the node of the first loop's `| done` arm, so its
// handlers must be MORE indented than that arm (4). A `| done` at column 2
// is a SIBLING of the first loop's done — it attaches to the capture root,
// which is why the old pin tripped KORU028. The second loop's own done is
// optional and discarded; omit it rather than writing `| done |> _` (KORU054
// refuses a no-op on an optional branch).
import std/io

capture { sum: 0[i64], g: [4]i64{ 1, 2, 3, 4 } }
! as acc |> for(0..4)
    ! each i |> captured { sum: acc.sum + acc.g[i] }
  | done |> for(0..4)
    ! each j |> captured { sum: acc.sum + acc.g[j] }
| captured result |> std/io:print.ln("{{ result.sum:d }}")
