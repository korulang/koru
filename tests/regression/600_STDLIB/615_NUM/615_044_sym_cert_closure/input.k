import std/io
import std/sym

// exp + exp: h = 2e^x satisfies the same f'-f=0 law
std/sym:cert-seed(body: "p0=[-1]|p1=[1]")
| exact c1 |> std/sym:cert-seed(body: "p0=[-1]|p1=[1]")
    | exact c2 |> std/sym:cert-sum(a: c1, b: c2)
        | exact s |> std/io:print.ln("{{ s:s }}")
        | bad-cert m |> std/io:print.ln("{{ m:s }}")
    | bad-cert m |> std/io:print.ln("{{ m:s }}")
| bad-cert m |> std/io:print.ln("{{ m:s }}")

// exp * exp: e^(2x) satisfies h' = 2h
std/sym:cert-seed(body: "p0=[-1]|p1=[1]")
| exact c1 |> std/sym:cert-seed(body: "p0=[-1]|p1=[1]")
    | exact c2 |> std/sym:cert-prod(a: c1, b: c2)
        | exact s |> std/io:print.ln("{{ s:s }}")
        | bad-cert m |> std/io:print.ln("{{ m:s }}")
    | bad-cert m |> std/io:print.ln("{{ m:s }}")
| bad-cert m |> std/io:print.ln("{{ m:s }}")

// 1/(1-x) + exp: order <= 2 via sum closure
std/sym:cert-seed(body: "p0=[1,0]|p1=[-1,1]")
| exact c1 |> std/sym:cert-seed(body: "p0=[-1]|p1=[1]")
    | exact c2 |> std/sym:cert-sum(a: c1, b: c2)
        | exact s |> std/io:print.ln("{{ s:s }}")
        | bad-cert m |> std/io:print.ln("{{ m:s }}")
    | bad-cert m |> std/io:print.ln("{{ m:s }}")
| bad-cert m |> std/io:print.ln("{{ m:s }}")

// composition: named theorem refusal
std/sym:cert-seed(body: "p0=[-1]|p1=[1]")
| exact c1 |> std/sym:cert-seed(body: "p0=[-1]|p1=[1]")
    | exact c2 |> std/sym:cert-compose(outer: c1, inner: c2)
        | not-holonomic m |> std/io:print.ln("{{ m:s }}")
        | bad-cert m |> std/io:print.ln("{{ m:s }}")
    | bad-cert m |> std/io:print.ln("{{ m:s }}")
| bad-cert m |> std/io:print.ln("{{ m:s }}")
