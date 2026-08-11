import std/io
import std/vendor

std/vendor:bindings {
    koru/vaxis: ./vendored/vaxis
}

import koru/vaxis

pub tor run {}
run = koru/vaxis:greet(): v |> std/io:print.ln("{{ v:s }}")
