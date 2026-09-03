// A host concept enters through the airlock: `File` is minted as an
// identity with observable fields, no derivation, no container. It erases
// to a marker; the name is what the type system can now reason about.
import std/io
import std/foreign

std/foreign:struct(File) {
    path,
    handle,
}

std/io:print.ln("registered")
