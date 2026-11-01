import std/io
import std/sym

// Seed certificates register laws for abstract/opaque generators: exp's f'-f=0.
std/sym:cert-seed(body: "p0=[-1]|p1=[1]")
| exact c |> std/sym:cert-shift(c)
    | exact s |> std/io:print.ln("{{ s:s }}")
    | bad-cert m |> std/io:print.ln("{{ m:s }}")
| bad-cert m |> std/io:print.ln("{{ m:s }}")

// Derived certs shift too: integral of sqrt(1+x), matching HolonomicCertificate.integralShift.
std/sym:lit(√((1e0+x)))
| exact a |> std/sym:derive-ode(a, max-order: 2, max-deg: 2)
    | exact c1 |> std/sym:cert-shift(c: c1)
        | exact s |> std/io:print.ln("{{ s:s }}")
        | bad-cert m |> std/io:print.ln("{{ m:s }}")
    | not-found |> std/io:print.ln("not-found")
    | non-analytic |> std/io:print.ln("non-analytic")
    | non-rational |> std/io:print.ln("non-rational")
    | bad |> std/io:print.ln("bad")
| bad |> std/io:print.ln("bad-lit")

// Malformed external cert text (piped stdin) refuses by name.
std/io:read-stdin()
| ok junk |> std/sym:cert-shift(c: junk)
    | exact s |> std/io:print.ln("{{ s:s }}")
    | bad-cert m |> std/io:print.ln("{{ m:s }}")
| eof |> std/io:print.ln("eof")
| failed _ |> std/io:print.ln("ff")

std/sym:cert-seed(body: "|p0=[")
| exact c |> std/io:print.ln("{{ c:s }}")
| bad-cert m |> std/io:print.ln("{{ m:s }}")
