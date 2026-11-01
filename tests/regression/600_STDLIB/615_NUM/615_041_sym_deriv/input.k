// std/sym:deriv — structural differentiation w.r.t. the free variable x.
// Constants derive to zero; the product rule unfolds over the canonical
// factor list; inv(f) lands -f'·inv(f)²; sq(f) lands f'·(1/2)·inv(√f).
// The result runs through the same norm, so derivates are canonical.
import std/io
import std/sym

std/sym:lit { x }
| exact s1 |> std/sym:deriv(a: s1): r |> std/io:print.ln("{{ r:s }}") |> std/sym:free(n: r)
| bad |> std/io:print.ln("bad")

std/sym:lit { π }
| exact s2 |> std/sym:deriv(a: s2): r |> std/io:print.ln("{{ r:s }}") |> std/sym:free(n: r)
| bad |> std/io:print.ln("bad")

std/sym:lit { x*x }
| exact s3 |> std/sym:deriv(a: s3): r |> std/io:print.ln("{{ r:s }}") |> std/sym:free(n: r)
| bad |> std/io:print.ln("bad")

std/sym:lit { x*x*x }
| exact s4 |> std/sym:deriv(a: s4): r |> std/io:print.ln("{{ r:s }}") |> std/sym:free(n: r)
| bad |> std/io:print.ln("bad")

std/sym:lit { (x+π) }
| exact s5 |> std/sym:deriv(a: s5): r |> std/io:print.ln("{{ r:s }}") |> std/sym:free(n: r)
| bad |> std/io:print.ln("bad")

std/sym:lit { π*x }
| exact s6 |> std/sym:deriv(a: s6): r |> std/io:print.ln("{{ r:s }}") |> std/sym:free(n: r)
| bad |> std/io:print.ln("bad")

std/sym:lit { inv(x) }
| exact s7 |> std/sym:deriv(a: s7): r |> std/io:print.ln("{{ r:s }}") |> std/sym:free(n: r)
| bad |> std/io:print.ln("bad")

std/sym:lit { √(x) }
| exact s8 |> std/sym:deriv(a: s8): r |> std/io:print.ln("{{ r:s }}") |> std/sym:free(n: r)
| bad |> std/io:print.ln("bad")

std/sym:lit { x/x }
| exact s9 |> std/sym:deriv(a: s9): r |> std/io:print.ln("{{ r:s }}") |> std/sym:free(n: r)
| bad |> std/io:print.ln("bad")

std/sym:lit { (x*x)+(π*x) }
| exact s10 |> std/sym:deriv(a: s10): r |> std/io:print.ln("{{ r:s }}") |> std/sym:free(n: r)
| bad |> std/io:print.ln("bad")
