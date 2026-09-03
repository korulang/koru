// The host owns the arrangement, so derivations may not build from it. A
// proto field naming a foreign entry is refused at the declaration — no
// embedding of host-owned bytes into a Koru derivation, in either direction.
import std/proto
import std/foreign

std/foreign:struct(File) {
    path
}

std/proto(Doc) {
    file: File
}
