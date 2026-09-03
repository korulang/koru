// The Koru-layer deref check (rung 2): `f.bogus` names no registered field,
// so the projection is refused here, in Koru's voice, naming the field and
// the entry — it never reaches the backend. The CONTAINS below discriminates
// that layer (Zig's undeclared-identifier error never names `bogus`).
// Present fields wave through to host linkage (667_005).
import std/io
import std/foreign

std/foreign:struct(File) {
    path
    handle
}

pub tor get-bogus { f: *File } -> string

get-bogus -> f.bogus
