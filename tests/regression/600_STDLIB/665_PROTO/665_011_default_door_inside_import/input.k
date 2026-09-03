// The default door inside an imported module. `std/proto(Scout)` here
// rewrites to `std.proto:default` exactly as it does in the entry file —
// each scope resolves against its own imports.
import app/lib
import std/io

std/io:print.ln("door")
