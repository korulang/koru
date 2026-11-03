import std/io
import std/sym

// B3a: the exp node and the principal complex log. exp(0)->1, exp(1)->e,
// exp(log u)->u and exp(c*log u)->u^c for small |c| (the canon has no pow
// node — inv(u)*inv(u) is the u^-2 form). exp factors merge over sums and
// inv(exp u)->exp(-u); d exp(u)/dx = u'*exp(u). log of a Q(i) constant is
// (1/2)log(a^2+b^2) + i*arg on the principal branch — quadrant-aware, so
// log(-1+i) -> 1/2 log 2 + 3i*pi/4. exp(i) stays symbolic: the cos/sin
// lanes it needs are B3b territory.

std/sym:lit(exp(0e0))
| exact a |> std/io:print.ln("{{ a:s }}") |> std/sym:free(n: a)
| bad |> std/io:print.ln("bad")

std/sym:lit(exp(1e0))
| exact a |> std/io:print.ln("{{ a:s }}") |> std/sym:free(n: a)
| bad |> std/io:print.ln("bad")

std/sym:lit(exp(x))
| exact a |> std/io:print.ln("{{ a:s }}") |> std/sym:free(n: a)
| bad |> std/io:print.ln("bad")

std/sym:lit(exp(log(x)))
| exact a |> std/io:print.ln("{{ a:s }}") |> std/sym:free(n: a)
| bad |> std/io:print.ln("bad")

std/sym:lit(exp((2e0*log(x))))
| exact a |> std/io:print.ln("{{ a:s }}") |> std/sym:free(n: a)
| bad |> std/io:print.ln("bad")

std/sym:lit(exp((-2e0*log(x))))
| exact a |> std/io:print.ln("{{ a:s }}") |> std/sym:free(n: a)
| bad |> std/io:print.ln("bad")

std/sym:lit(exp(x)*exp((1e0+x)))
| exact a |> std/io:print.ln("{{ a:s }}") |> std/sym:free(n: a)
| bad |> std/io:print.ln("bad")

std/sym:lit(exp(x)*exp(x))
| exact a |> std/io:print.ln("{{ a:s }}") |> std/sym:free(n: a)
| bad |> std/io:print.ln("bad")

std/sym:lit(inv(exp(x)))
| exact a |> std/io:print.ln("{{ a:s }}") |> std/sym:free(n: a)
| bad |> std/io:print.ln("bad")

std/sym:lit(exp(x)*inv(exp(x)))
| exact a |> std/io:print.ln("{{ a:s }}") |> std/sym:free(n: a)
| bad |> std/io:print.ln("bad")

std/sym:lit(exp(x))
| exact a |> std/sym:deriv(a)
    |> std/io:print.ln("{{ a:s }}") |> std/sym:free(n: a)
| bad |> std/io:print.ln("bad")

std/sym:lit(exp((x*x)))
| exact a |> std/sym:deriv(a)
    |> std/io:print.ln("{{ a:s }}") |> std/sym:free(n: a)
| bad |> std/io:print.ln("bad")

std/sym:lit(log(i))
| exact a |> std/io:print.ln("{{ a:s }}") |> std/sym:free(n: a)
| bad |> std/io:print.ln("bad")

std/sym:lit(log((2e0*i)))
| exact a |> std/io:print.ln("{{ a:s }}") |> std/sym:free(n: a)
| bad |> std/io:print.ln("bad")

std/sym:lit(log((-1e0*i)))
| exact a |> std/io:print.ln("{{ a:s }}") |> std/sym:free(n: a)
| bad |> std/io:print.ln("bad")

std/sym:lit(log(-4e0))
| exact a |> std/io:print.ln("{{ a:s }}") |> std/sym:free(n: a)
| bad |> std/io:print.ln("bad")

std/sym:lit(log(-1e0))
| exact a |> std/io:print.ln("{{ a:s }}") |> std/sym:free(n: a)
| bad |> std/io:print.ln("bad")

std/sym:lit(log((1e0+i)))
| exact a |> std/io:print.ln("{{ a:s }}") |> std/sym:free(n: a)
| bad |> std/io:print.ln("bad")

std/sym:lit(log((-1e0+i)))
| exact a |> std/io:print.ln("{{ a:s }}") |> std/sym:free(n: a)
| bad |> std/io:print.ln("bad")

std/sym:lit(exp(i))
| exact a |> std/io:print.ln("{{ a:s }}") |> std/sym:free(n: a)
| bad |> std/io:print.ln("bad")
