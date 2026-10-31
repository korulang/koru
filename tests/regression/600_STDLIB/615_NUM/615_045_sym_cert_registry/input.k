import std/io
import std/sym

// Registry: seed exp's law, shift it (integral), sum exp+exp,
// prod exp*exp, derive sqrt(1+x), then inspect the blob's contents.
std/sym:cert-reg-new(): r0
|> std/sym:cert-reg-seed(reg: r0, body: "p0=[-1]|p1=[1]")
    | exact r1 |> std/sym:cert-reg-shift(reg: r1, key: "G1")
        | exact r2 |> std/sym:cert-reg-sum(reg: r2, a: "G1", b: "G1")
            | exact r3 |> std/sym:cert-reg-prod(reg: r3, a: "G1", b: "G1")
                | exact r4 |> std/sym:lit(s: "√((1e0+x))")
                    | exact e |> std/sym:cert-reg-derive(reg: r4, a: e, max-order: 2, max-deg: 2)
                        | exact r5 |> std/sym:cert-reg-get(reg: r5, key: "G5")
                            | exact c |> std/io:print.ln("{{ c:s }}") |> std/io:free(content: c)
                                |> std/sym:cert-reg-get(reg: r5, key: "G4")
                                | exact c2 |> std/io:print.ln("{{ c2:s }}") |> std/io:free(content: c2)
                                    |> std/sym:cert-reg-last(reg: r5)
                                    | exact k |> std/io:print.ln("{{ k:s }}") |> std/io:free(content: k)
                                        |> std/io:print.ln("{{ r5:s }}") |> std/io:free(content: r5)
                                    | empty |> std/io:print.ln("empty")
                                    | bad-cert m3 |> std/io:print.ln("{{ m3:s }}") |> std/io:free(content: m3)
                                | not-found |> std/io:print.ln("nf4")
                                | bad-cert m2 |> std/io:print.ln("{{ m2:s }}") |> std/io:free(content: m2)
                            | not-found |> std/io:print.ln("nf5")
                            | bad-cert m |> std/io:print.ln("{{ m:s }}") |> std/io:free(content: m)
                        | not-found |> std/io:print.ln("nf-derive")
                        | non-analytic |> std/io:print.ln("na")
                        | non-rational |> std/io:print.ln("nr")
                        | bad |> std/io:print.ln("bad")
                        | bad-cert m |> std/io:print.ln("{{ m:s }}") |> std/io:free(content: m)
                    | bad |> std/io:print.ln("bad-lit")
                | not-found |> std/io:print.ln("nf-prod")
                | bad-cert m |> std/io:print.ln("{{ m:s }}") |> std/io:free(content: m)
            | not-found |> std/io:print.ln("nf-sum")
            | bad-cert m |> std/io:print.ln("{{ m:s }}") |> std/io:free(content: m)
        | not-found |> std/io:print.ln("nf-shift")
        | bad-cert m |> std/io:print.ln("{{ m:s }}") |> std/io:free(content: m)
    | bad-cert m |> std/io:print.ln("{{ m:s }}") |> std/io:free(content: m)

// Missing key refuses not-found
std/sym:cert-reg-new(): q0
|> std/sym:cert-reg-get(reg: q0, key: "G1")
    | exact c |> std/io:print.ln("{{ c:s }}") |> std/io:free(content: c) |> std/io:free(content: q0)
    | not-found |> std/io:print.ln("nf-empty") |> std/io:free(content: q0)
    | bad-cert m |> std/io:print.ln("{{ m:s }}") |> std/io:free(content: m) |> std/io:free(content: q0)
