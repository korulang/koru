// ACCEPTANCE PIN — GREEN since the EFFECT INLINING relowering (2026-06-13):
// the real-input accumulator (file → lines → match → cell). Effectful
// events compile to one flat monomorphized frame at the invocation site —
// the proc body splices in, handler bodies land IN FLOW SCOPE where the
// cell is an ordinary local. No Handlers struct, no namespace boundary,
// no side channels. (History: callback lowering made this impossible; a
// threadlocal spine band-aid was built and REVERTED on ruling.)

import std/io
import std/fs
import std/regex

capture { hits: 0[i64] }
! as acc |> std/fs:read-lines(path: "tests/regression/600_STDLIB/650_FS/650_004_capture_across_handler_boundary/input.txt")
    ! line l |> std/regex:match(l)
        | `[0-9]+` _ |> captured { hits: acc.hits + 1 }
        | no-match |> _
    | done _ |> _
    | failed e |> std/io:print.ln("FAILED: {{ e:s }}")
| captured total |> std/io:print.ln("{{ total.hits:d }} number lines")
