import std/io
import std/sym

// B2: the imaginary atom i and the Q(i) constant ring. i*i -> -1e0 is the
// smallest fold; (a+bi)(c+di) collapses through the ring even beside
// non-constant factors (i*x*i -> -x); inv is conjugate over norm;
// sqrt(-d) -> i*sqrt(|d|). log(i) stays symbolic — the complex log is B3.

std/sym:lit(i)
| exact a |> std/io:print.ln("{{ a:s }}") |> std/sym:free(n: a)
| bad |> std/io:print.ln("bad")

std/sym:lit(i*i)
| exact a |> std/io:print.ln("{{ a:s }}") |> std/sym:free(n: a)
| bad |> std/io:print.ln("bad")

std/sym:lit(i*i*i)
| exact a |> std/io:print.ln("{{ a:s }}") |> std/sym:free(n: a)
| bad |> std/io:print.ln("bad")

std/sym:lit(i*i*i*i)
| exact a |> std/io:print.ln("{{ a:s }}") |> std/sym:free(n: a)
| bad |> std/io:print.ln("bad")

std/sym:lit((1e0+i)*(1e0+(-1e0*i)))
| exact a |> std/io:print.ln("{{ a:s }}") |> std/sym:free(n: a)
| bad |> std/io:print.ln("bad")

std/sym:lit((2e0+i)*(3e0+(-1e0*i)))
| exact a |> std/io:print.ln("{{ a:s }}") |> std/sym:free(n: a)
| bad |> std/io:print.ln("bad")

std/sym:lit(i*x*i)
| exact a |> std/io:print.ln("{{ a:s }}") |> std/sym:free(n: a)
| bad |> std/io:print.ln("bad")

std/sym:lit(inv(i))
| exact a |> std/io:print.ln("{{ a:s }}") |> std/sym:free(n: a)
| bad |> std/io:print.ln("bad")

std/sym:lit(inv((1e0+i)))
| exact a |> std/io:print.ln("{{ a:s }}") |> std/sym:free(n: a)
| bad |> std/io:print.ln("bad")

std/sym:lit(inv((2e0+i)))
| exact a |> std/io:print.ln("{{ a:s }}") |> std/sym:free(n: a)
| bad |> std/io:print.ln("bad")

std/sym:lit(√(-1e0))
| exact a |> std/io:print.ln("{{ a:s }}") |> std/sym:free(n: a)
| bad |> std/io:print.ln("bad")

std/sym:lit(√(-4e0))
| exact a |> std/io:print.ln("{{ a:s }}") |> std/sym:free(n: a)
| bad |> std/io:print.ln("bad")

std/sym:lit(√(-2e0))
| exact a |> std/io:print.ln("{{ a:s }}") |> std/sym:free(n: a)
| bad |> std/io:print.ln("bad")

std/sym:lit(1e0+i)
| exact a |> std/io:print.ln("{{ a:s }}") |> std/sym:free(n: a)
| bad |> std/io:print.ln("bad")

std/sym:lit(i+i)
| exact a |> std/io:print.ln("{{ a:s }}") |> std/sym:free(n: a)
| bad |> std/io:print.ln("bad")

std/sym:lit(i+(-1e0*i))
| exact a |> std/io:print.ln("{{ a:s }}") |> std/sym:free(n: a)
| bad |> std/io:print.ln("bad")

std/sym:lit(i*x)
| exact a |> std/sym:deriv(a): d
    |> std/io:print.ln("{{ d:s }}") |> std/sym:free(n: d)
| bad |> std/io:print.ln("bad")

std/sym:lit(i*inv(i))
| exact a |> std/io:print.ln("{{ a:s }}") |> std/sym:free(n: a)
| bad |> std/io:print.ln("bad")

std/sym:lit(log(i))
| exact a |> std/io:print.ln("{{ a:s }}") |> std/sym:free(n: a)
| bad |> std/io:print.ln("bad")
