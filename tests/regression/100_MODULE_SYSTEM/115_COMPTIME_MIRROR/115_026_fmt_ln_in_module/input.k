// MIRROR of 620_001_fmt_ln_basic: a tor implemented by `std/fmt:ln`, relocated
// into an imported module.
//
// The original already implements a tor with the transform, so what moves is
// the tor's home. The formatted text is returned across the module boundary via
// a bare-return, which is the shape a formatting helper in a library has.
import std/io
import app/lib

app/lib:greet(name: "World"): g |> std/io:print.ln(g)
