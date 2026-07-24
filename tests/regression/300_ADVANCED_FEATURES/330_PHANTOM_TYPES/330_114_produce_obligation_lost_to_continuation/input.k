// The `->` twin of 330_113: an obligation PRODUCED through a value-return
// subflow is tracked correctly across the produce — `fetch(): lamp` on its own
// is caught (KORU030) — and is then lost the moment the caller's bind acquires
// a continuation. Same root, second surface.
//
// This pins that the defect is NOT specific to the `:` bind form. `:` capture
// and `->` produce carry the obligation identically, and both forget it at the
// same place: a whole-value obligation live on a bound head that has a
// continuation. The produce path is worth its own pin because it is the one
// that survives a subflow boundary, so a fix that only re-seeds at the direct
// call site would leave this shape red.
import std/io
import app/lantern

tor fetch { } -> *app/lantern:Lantern<lit!>

fetch = app/lantern:light(): l -> l

fetch(): lamp |> std/io:print.ln("in the dark")
