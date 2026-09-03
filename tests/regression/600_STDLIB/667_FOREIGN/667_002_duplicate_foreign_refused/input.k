// One home, one File. A second registration of the same foreign entry is
// the same loud collision as any other identity door — the airlock mints
// once, never merges.
import std/foreign

std/foreign:struct(File) {
    path
}

std/foreign:struct(File) {
    handle
}
