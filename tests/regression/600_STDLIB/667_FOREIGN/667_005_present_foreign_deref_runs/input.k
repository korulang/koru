// PINNED GAP (currently RED) — the full journey of a present-field deref.
// `f.path` is registered, so the Koru layer will wave it through even after
// the deref check lands (667_004); what fails TODAY is one stage later — the
// emitted Zig names a `File` type nothing declares, because host linkage
// (what a `*File` lowers to, and where its declaration comes from) is
// unbuilt. Greens when the projection compiles end-to-end; execution with a
// real File is a further rung still. The print proves the program RAN, not
// just compiled, on that day.
import std/io
import std/foreign

std/foreign:struct(File) {
    path,
    handle,
}

pub tor get-path { f: *File } -> string

get-path -> f.path

std/io:print.ln("ok")
