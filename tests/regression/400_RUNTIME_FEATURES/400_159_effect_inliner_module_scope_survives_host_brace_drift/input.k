// 400_159 — the `\\ }` inside lib/drift.kz's `fn note` drifts the host
// brace counter; the effect proc's bare `k` (a for-capture, not a module
// name) must NOT be flagged KORU112. Program runs clean.
import std/io
import app/lib/drift

app/lib/drift:spin(count: 3)
! tick k |> std/io:print.ln("tick {{ k:d }}")
| done t |> std/io:print.ln("done {{ t:d }}")
