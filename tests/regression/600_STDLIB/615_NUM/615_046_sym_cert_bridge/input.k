import std/io
import std/sym

// exp's law -f + f' = 0 -> -(a_n) + (n+1)a_{n+1} = 0
std/sym:cert-seed(body: "p0=[-1]|p1=[1]")
| exact c |> std/sym:cert-bridge(c)
    | exact r |> std/io:print.ln("{{ r:s }}") |> std/io:free(content: r)
    | bad-cert m |> std/io:print.ln("{{ m:s }}") |> std/io:free(content: m)
| bad-cert m |> std/io:print.ln("{{ m:s }}") |> std/io:free(content: m)

// 1/(1-x): constant coefficients
std/sym:cert-seed(body: "p0=[1,0]|p1=[-1,1]")
| exact c |> std/sym:cert-bridge(c)
    | exact r |> std/io:print.ln("{{ r:s }}") |> std/io:free(content: r)
    | bad-cert m |> std/io:print.ln("{{ m:s }}") |> std/io:free(content: m)
| bad-cert m |> std/io:print.ln("{{ m:s }}") |> std/io:free(content: m)

// sqrt(1+x) discovered -> bridged: (2n+1)a_{n+1} + (2n+4)a_{n+2} = 0
std/sym:lit(√((1e0+x)))
| exact a |> std/sym:derive-ode(a, max-order: 2, max-deg: 2)
    | exact c |> std/sym:cert-bridge(c)
        | exact r |> std/io:print.ln("{{ r:s }}") |> std/io:free(content: r)
        | bad-cert m |> std/io:print.ln("{{ m:s }}") |> std/io:free(content: m)
    | not-found |> std/io:print.ln("nf")
    | non-analytic |> std/io:print.ln("na")
    | non-rational |> std/io:print.ln("nr")
    | bad |> std/io:print.ln("bad")
| bad |> std/io:print.ln("bad-lit")

// q_{K,0} = 0: leading bridge poly vanishes -> det=0, order drops
std/sym:cert-seed(body: "p0=[1]|p1=[0,1]")
| exact c |> std/sym:cert-bridge(c)
    | exact r |> std/io:print.ln("{{ r:s }}") |> std/io:free(content: r)
    | bad-cert m |> std/io:print.ln("{{ m:s }}") |> std/io:free(content: m)
| bad-cert m |> std/io:print.ln("{{ m:s }}") |> std/io:free(content: m)

// malformed external cert through the allocated stdin path
std/io:read-stdin()
| ok junk |> std/sym:cert-bridge(c: junk)
    | exact r |> std/io:print.ln("{{ r:s }}") |> std/io:free(content: r)
    | bad-cert m |> std/io:print.ln("{{ m:s }}") |> std/io:free(content: m)
| eof |> std/io:print.ln("eof")
| failed _ |> std/io:print.ln("ff")
