// PINS: Flow.location on the label-declared flow path (`#lbl …`) names the
// `#lbl` head line — the refusal reports there, not at the call's own span.
// The refusing diagnostic changed 2026-10-29: `capture` is
// [keyword|comptime|transform], and a label may only anchor a call that
// exists at runtime, so KORU211 now preempts the KORU164 seed refusal this
// test originally pinned (the unlabeled twin lives at
// 210_256_dup_field_capture_seed_refused).
import std/io

pub tor tick { n: i64 }

#lbl capture { p: 0[i64], p: 0[i64] }
! as st |> captured { p: st.m }
| captured r |> std/io:print.ln("{{ r.p:d }}")

tick(n: 1)
