import std/io
import std/sym

// Kovacic case 1, rational-pole Fuchs slice: poles of order <=2 with
// rational exponents, o(inf) >= 2. The lane enumerates exponent choices
// and null-spaces the cleared polynomial system for P — a found P is a
// proof; outside the slice each boundary is named, never guessed.

// y'' = 2/x^2 y -> y = x^2 (single double pole, e_0 = 2, P = 1)
std/sym:lit(2*inv(x*x))
| exact r |> std/sym:decide-ode(r)
    | liouvillian m |> std/io:print.ln("{{ m:s }}")
    | holonomic-special m |> std/io:print.ln("hs:{{ m:s }}")
    | unclassifiable m |> std/io:print.ln("un:{{ m:s }}")
    | bad m |> std/io:print.ln("bad:{{ m:s }}")
| bad |> std/io:print.ln("bad-literal")

// y'' = (2/(x(x-1))) y -> y = x(x-1) (two simple poles, e_inf = 2, P = 1)
std/sym:lit(2*inv(x*(x+(-1e0))))
| exact r |> std/sym:decide-ode(r)
    | liouvillian m |> std/io:print.ln("{{ m:s }}")
    | holonomic-special m |> std/io:print.ln("hs:{{ m:s }}")
    | unclassifiable m |> std/io:print.ln("un:{{ m:s }}")
    | bad m |> std/io:print.ln("bad:{{ m:s }}")
| bad |> std/io:print.ln("bad-literal")

// y'' = (2/(x^2(x+1))) y -> y = (x+1)/x (o(inf) = 3, e_inf = 1, e_0 = -1)
std/sym:lit(2*inv(x*x*(x+1e0)))
| exact r |> std/sym:decide-ode(r)
    | liouvillian m |> std/io:print.ln("{{ m:s }}")
    | holonomic-special m |> std/io:print.ln("hs:{{ m:s }}")
    | unclassifiable m |> std/io:print.ln("un:{{ m:s }}")
    | bad m |> std/io:print.ln("bad:{{ m:s }}")
| bad |> std/io:print.ln("bad-literal")

// order-4 pole: even, so the case-1 necessary check survives — but the
// lane only reaches poles of order <= 2 and names that bound
std/sym:lit(inv(x*x*x*x))
| exact r |> std/sym:decide-ode(r)
    | liouvillian m |> std/io:print.ln("{{ m:s }}")
    | holonomic-special m |> std/io:print.ln("hs:{{ m:s }}")
    | unclassifiable m |> std/io:print.ln("un:{{ m:s }}")
    | bad m |> std/io:print.ln("bad:{{ m:s }}")
| bad |> std/io:print.ln("bad-literal")

// algebraic poles: x^2-2 splits at +-sqrt(2), outside rational-pole reach
std/sym:lit(2*inv(x*x+(-2e0)))
| exact r |> std/sym:decide-ode(r)
    | liouvillian m |> std/io:print.ln("{{ m:s }}")
    | holonomic-special m |> std/io:print.ln("hs:{{ m:s }}")
    | unclassifiable m |> std/io:print.ln("un:{{ m:s }}")
    | bad m |> std/io:print.ln("bad:{{ m:s }}")
| bad |> std/io:print.ln("bad-literal")

// irrational exponent: b_0 = 1 gives 1+4b = 5, not a rational square
std/sym:lit(inv(x*x))
| exact r |> std/sym:decide-ode(r)
    | liouvillian m |> std/io:print.ln("{{ m:s }}")
    | holonomic-special m |> std/io:print.ln("hs:{{ m:s }}")
    | unclassifiable m |> std/io:print.ln("un:{{ m:s }}")
    | bad m |> std/io:print.ln("bad:{{ m:s }}")
| bad |> std/io:print.ln("bad-literal")
