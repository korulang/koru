// PIN: a string<unsanitized!> value is passed to a tor whose parameter is plain
// `string` — no phantom annotation. The callee is not phantom-aware, so it can
// neither discharge the obligation nor launder it: the caller must still hold
// <unsanitized!> after the call, and scope exit must refuse.
//
// The positive twin (330_068) shows <unsanitized!> passed to <!unsanitized>
// discharging correctly. This pins the BOUNDARY case: an untyped sink must NOT
// strip the taint (Aldrich typestate, Onward! 2009: typestate must be preserved
// through composition — silently laundering taint through a non-phantom-aware
// sink would be a security-critical gap).
//
// Grounding:
//   string<unsanitized!> + literal bare-return impl — 330_068/input.k
//   subflow impl via std/io:print.ln              — 330_068/input.k

import std/io

pub tor get-input {} -> string<unsanitized!>

get-input -> "user input data"

// Sink that takes a PLAIN string — no phantom annotation, cannot discharge.
tor log-raw { data: string }

log-raw = std/io:print.ln(data)

get-input(): s |> log-raw(data: s)
