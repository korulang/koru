// Test: print.ln with Koru-scoped bindings (from capture) — BLOCK FORM.

import std/io
import std/control

// Use capture to create a Koru binding, then print it
capture { total: 0[i32] }
! as acc |> captured { total: acc.total + 42 }
| captured final |> std/io:print.ln("Captured total: {{ final.total:d }}")
