// PINS: every interceptor body on a store declaration is ordinary Koru, so a
// comptime transform inside one expands the way it does anywhere else.
//
// `! discharge` is the IN-FILE CONTROL —
// its body is the same shape as the other two and its `print.ln` does expand,
// interpolation and all. That is what makes this a pin on an ASYMMETRY rather
// than on a missing feature: the declaration site already knows how to run an
// arm body, and two of its arms do not get it.
//
// `std/io:print.ln` is `~[keyword|comptime|transform]` (io.kz:240) — a call site
// the compiler REWRITES into inline Zig. Where the rewrite does not happen the
// call survives as a plain event taking the raw template as `expr`, whose result
// is discarded: silent, and indistinguishable at the source from a wired arm.
//
// The mechanism the two paths differ by: `! discharge` rides the teardown flow
// as an ordinary appended flow (store.kz:3646, `impl_of = null`), while
// inserted/removed/updated go through `LC.emit` (store.kz:3304), which appends a
// `retain`ed event_decl plus its implementing subflow. The bodies that expand
// are the ones on the first path.
//
// This is the store's face of frag-two-lowerings-share-one-contract, and of the
// standing question whether synthesized surface re-enters normalization. A
// lifecycle arm is authored surface by every measure its author can see.
import std/io
import std/store
import app/lib/src

std/store:new(batch, capacity: 2) { *app/lib/src:Src<live!> }
! inserted _ |> std/io:print.ln("arm inserted")
! discharge s |> app/lib/src:close(s): id |> std/io:print.ln("arm discharge {{ id:d }}")

std/io:print.ln("start")
app/lib/src:open(id: 9, work: 1): a |> std/store:insert(batch) { a }
| row _ |> std/io:print.ln("inserted")
| full f |> app/lib/src:close(s: f): id |> std/io:print.ln("full {{ id:d }}")
