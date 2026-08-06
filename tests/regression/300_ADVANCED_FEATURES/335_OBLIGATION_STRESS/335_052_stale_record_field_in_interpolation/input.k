// PIN: a discharged RECORD FIELD read through a `{{ }}` interpolation escapes
// the use-after-discharge wall.
//
// Both halves work on their own, which is what makes this the two-lowerings
// shape rather than a missing feature:
//
//   plain binding  + argument      -> caught (335_024, 335_025, 335_047)
//   plain binding  + interpolation -> caught
//   record field   + argument      -> caught ("binding 'r.k' was already
//                                     discharged" — the composite key IS the
//                                     name the checker reports)
//   record field   + interpolation -> THIS TEST
//
// phantom_semantic_checker.zig's interpolation scanner walks a slot for
// identifiers and skips any segment preceded by `.`, on the stated ground that
// "a trailing `.field` names a field, not a binding". True for an ordinary
// record — and the exact case that misses here, because an obligation carried
// on a record field is disposed under `r.k`, a name the scan never forms.
//
// Found while testing whether a borrow could be tied to its owner by minting
// two obligations and discharging them together (610_007's open question). The
// tie held; this is what leaked out from under it.

import app/holder
import std/io

app/holder:grab(name: "x"): r |> app/holder:drop(h: r.k) |> std/io:print.ln("{{ r.k:s }}")
