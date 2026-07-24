// The `->` twin of 330_113: an obligation PRODUCED through a value-return
// subflow crosses the subflow boundary intact and is still enforced at the
// caller's flow exit, continuation and all.
//
// Worth its own pin because it is the shape that survives a subflow boundary —
// the obligation reaches the caller through `fetch`'s declared return type
// rather than from the minting call directly. An exit check wired only at the
// direct call site would satisfy 330_113 and leave this one unguarded, so the
// pair is what pins "`:` bind and `->` produce carry obligations identically".
import std/io
import app/lantern

tor fetch { } -> *app/lantern:Lantern<lit!>

fetch = app/lantern:light(): l -> l

fetch(): lamp |> std/io:print.ln("in the dark")
