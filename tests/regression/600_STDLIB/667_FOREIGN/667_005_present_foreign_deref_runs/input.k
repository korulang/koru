// The full journey of a present-field deref, across an import: the entry
// and its host proof live in app/lib; the consumer derefs through the
// import. `f.path` is registered, so the Koru layer waves it through (rung
// 2); host linkage routes `*File` to the declaring home and the projection
// compiles end-to-end. Execution with a real File is a further rung still —
// get-path is never called. The print proves the program RAN, not just
// compiled, on that day.
import app/lib
import std/io

pub tor get-path { f: *File } -> string

get-path -> f.path

std/io:print.ln("ok")
