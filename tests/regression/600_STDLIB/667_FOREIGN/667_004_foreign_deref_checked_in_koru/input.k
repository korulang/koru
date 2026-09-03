// PINNED GAP (currently RED) — the deref check does not exist yet. `f.bogus`
// names no registered field, but Koru waves the projection through and the
// backend fails with Zig's `undeclared identifier 'File'` — the same error
// the PRESENT field (667_005) dies with. Koru cannot tell them apart.
// Greens the day the projection is refused at the Koru layer with an error
// naming the field and the entry; the CONTAINS below already discriminates
// that day (Zig's error never names `bogus`).
import std/io
import std/foreign

std/foreign:struct(File) {
    path,
    handle,
}

pub tor get-bogus { f: *File } -> string

get-bogus -> f.bogus
