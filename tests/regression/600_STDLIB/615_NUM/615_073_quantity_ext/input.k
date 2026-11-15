// std/quantity: non-SI extension — declared axes live in the !ext=
// segment, a second free-abelian group disjoint from the seven SI dims.
// lit-x constructs them over a unitreg; mul/div compose exponents,
// add/sub require ext equality, pow scales them, convert-x is the
// oracle — it re-taints its result external, never a group law.
import std/io
import std/quantity

// lit-x: USD axis -> !ext=USD^1
std/quantity:unit-reg-new(): r0
|> std/quantity:unit-reg-decls(reg: r0, source: "USD=axis(currency);EUR=axis(currency)")
    | exact ureg |> std/quantity:lit-x(5 USD, ureg)
        | exact q |> std/quantity:render(n: q): t |> std/io:print.ln("{{ t:s }}") |> std/io:free(content: t) |> std/io:free(content: ureg)
        | undeclared-axis e |> std/io:print.ln("u1") |> std/io:free(content: e) |> std/io:free(content: ureg)
        | bad e |> std/io:print.ln("b1") |> std/io:free(content: e) |> std/io:free(content: ureg)
    | dup |> std/io:print.ln("dup")
    | bad |> std/io:print.ln("bad:reg")

// rate spelling: 1.1 EUR/USD -> !ext=EUR^1·USD^-1
std/quantity:unit-reg-new(): r1
|> std/quantity:unit-reg-decls(reg: r1, source: "USD=axis(currency);EUR=axis(currency)")
    | exact ureg |> std/quantity:lit-x(1.1 EUR/USD, ureg)
        | exact q |> std/quantity:render(n: q): t |> std/io:print.ln("{{ t:s }}") |> std/io:free(content: t) |> std/io:free(content: ureg)
        | undeclared-axis e |> std/io:print.ln("u2") |> std/io:free(content: e) |> std/io:free(content: ureg)
        | bad e |> std/io:print.ln("b2") |> std/io:free(content: e) |> std/io:free(content: ureg)
    | dup |> std/io:print.ln("dup")
    | bad |> std/io:print.ln("bad:reg")

// mul composes exponents: 5 USD * 1.1 EUR/USD -> 5.5 EUR
std/quantity:unit-reg-new(): r2
|> std/quantity:unit-reg-decls(reg: r2, source: "USD=axis(currency);EUR=axis(currency)")
    | exact ureg |> std/quantity:lit-x(5 USD, ureg)
        | exact q |> std/quantity:lit-x(1.1 EUR/USD, ureg)
            | exact rt |> std/quantity:mul(a: q, b: rt)
                | exact m |> std/quantity:render(n: m): tm |> std/io:print.ln("{{ tm:s }}") |> std/io:free(content: tm) |> std/io:free(content: ureg)
                | mixed-cov |> std/io:print.ln("mixed") |> std/io:free(content: ureg)
                | sym-unc |> std/io:print.ln("su") |> std/io:free(content: ureg)
                | bad e |> std/io:print.ln("badmul") |> std/io:free(content: ureg)
            | undeclared-axis e |> std/io:print.ln("u3") |> std/io:free(content: e) |> std/io:free(content: ureg)
            | bad e |> std/io:print.ln("b3") |> std/io:free(content: e) |> std/io:free(content: ureg)
        | undeclared-axis e |> std/io:print.ln("u4") |> std/io:free(content: e) |> std/io:free(content: ureg)
        | bad e |> std/io:print.ln("b4") |> std/io:free(content: e) |> std/io:free(content: ureg)
    | dup |> std/io:print.ln("dup")
    | bad |> std/io:print.ln("bad:reg")

// convert-x: the same composition, asserted onto the EUR axis and
// re-tainted — parse discharges the oracle claim back to exact.
std/quantity:unit-reg-new(): r3
|> std/quantity:unit-reg-decls(reg: r3, source: "USD=axis(currency);EUR=axis(currency)")
    | exact ureg |> std/quantity:lit-x(5 USD, ureg)
        | exact q |> std/quantity:lit-x(1.1 EUR/USD, ureg)
            | exact rt |> std/quantity:convert-x(q, rate: rt, axis: "EUR")
                | exact x |> std/quantity:parse(s: x)
                    | exact p |> std/quantity:render(n: p): tp |> std/io:print.ln("{{ tp:s }}") |> std/io:free(content: tp) |> std/io:free(content: ureg)
                    | bad m |> std/io:print.ln("convparse-bad") |> std/io:free(content: m) |> std/io:free(content: ureg)
                | axis-mismatch |> std/io:print.ln("ax") |> std/io:free(content: ureg)
                | mixed-cov |> std/io:print.ln("mc") |> std/io:free(content: ureg)
                | sym-unc |> std/io:print.ln("sc") |> std/io:free(content: ureg)
                | bad m |> std/io:print.ln("cb") |> std/io:free(content: ureg)
            | undeclared-axis e |> std/io:print.ln("u5") |> std/io:free(content: e) |> std/io:free(content: ureg)
            | bad e |> std/io:print.ln("b5") |> std/io:free(content: e) |> std/io:free(content: ureg)
        | undeclared-axis e |> std/io:print.ln("u6") |> std/io:free(content: e) |> std/io:free(content: ureg)
        | bad e |> std/io:print.ln("b6") |> std/io:free(content: e) |> std/io:free(content: ureg)
    | dup |> std/io:print.ln("dup")
    | bad |> std/io:print.ln("bad:reg")

// a rate that does not convert refuses by name
std/quantity:unit-reg-new(): r4
|> std/quantity:unit-reg-decls(reg: r4, source: "USD=axis(currency);EUR=axis(currency)")
    | exact ureg |> std/quantity:lit-x(5 USD, ureg)
        | exact q |> std/quantity:lit-x(2 EUR, ureg)
            | exact rt |> std/quantity:convert-x(q, rate: rt, axis: "EUR")
                | exact x |> std/quantity:parse(s: x)
                    | exact p |> std/io:print.ln("BUG") |> std/quantity:free(n: p)
                    | bad m |> std/io:print.ln("cpb2") |> std/io:free(content: m)
                | axis-mismatch |> std/io:print.ln("axis-mismatch")
                | mixed-cov |> std/io:print.ln("mc2")
                | sym-unc |> std/io:print.ln("sc2")
                | bad m |> std/io:print.ln("cb2")
            | undeclared-axis e |> std/io:print.ln("u7") |> std/io:free(content: e)
            | bad e |> std/io:print.ln("b7") |> std/io:free(content: e)
        | undeclared-axis e |> std/io:print.ln("u8") |> std/io:free(content: e)
        | bad e |> std/io:print.ln("b8") |> std/io:free(content: e)
        |> std/io:free(content: ureg)
    | dup |> std/io:print.ln("dup")
    | bad |> std/io:print.ln("bad:reg")

// an unregistered name refuses at the literal boundary
std/quantity:unit-reg-new(): r5
|> std/quantity:unit-reg-decls(reg: r5, source: "USD=axis(currency)")
    | exact ureg |> std/quantity:lit-x(5 JPY, ureg)
        | exact q |> std/quantity:render(n: q): t |> std/io:print.ln("BUG") |> std/io:free(content: t) |> std/io:free(content: ureg)
        | undeclared-axis e |> std/io:print.ln("undeclared-axis") |> std/io:free(content: e) |> std/io:free(content: ureg)
        | bad e |> std/io:print.ln("b9") |> std/io:free(content: e) |> std/io:free(content: ureg)
    | dup |> std/io:print.ln("dup")
    | bad |> std/io:print.ln("bad:reg")

// add requires ext equality — same group law as dim
std/quantity:unit-reg-new(): r6
|> std/quantity:unit-reg-decls(reg: r6, source: "USD=axis(currency);EUR=axis(currency)")
    | exact ureg |> std/quantity:lit-x(5 USD, ureg)
        | exact a |> std/quantity:lit-x(3 EUR, ureg)
            | exact b |> std/quantity:add(a, b)
                | exact s |> std/quantity:render(n: s): ts |> std/io:print.ln("BUG") |> std/io:free(content: ts)
                | dim-mismatch |> std/io:print.ln("dim-mismatch")
                | mixed-cov |> std/io:print.ln("mc3")
            | undeclared-axis e |> std/io:print.ln("u9") |> std/io:free(content: e)
            | bad e |> std/io:print.ln("b10") |> std/io:free(content: e)
        | undeclared-axis e |> std/io:print.ln("u10") |> std/io:free(content: e)
        | bad e |> std/io:print.ln("b11") |> std/io:free(content: e)
        |> std/io:free(content: ureg)
    | dup |> std/io:print.ln("dup")
    | bad |> std/io:print.ln("bad:reg")

// pow scales the ext exponents
std/quantity:unit-reg-new(): r7
|> std/quantity:unit-reg-decls(reg: r7, source: "USD=axis(currency)")
    | exact ureg |> std/quantity:lit-x(2 USD, ureg)
        | exact q |> std/quantity:pow(a: q, n: 2)
            | exact p |> std/quantity:render(n: p): tp |> std/io:print.ln("{{ tp:s }}") |> std/io:free(content: tp)
            | div-zero |> std/io:print.ln("dz")
            | sym-unc |> std/io:print.ln("su2")
            | exp-too-large |> std/io:print.ln("etl")
            | bad m |> std/io:print.ln("pb")
        | undeclared-axis e |> std/io:print.ln("u11") |> std/io:free(content: e)
        | bad e |> std/io:print.ln("b12") |> std/io:free(content: e)
        |> std/io:free(content: ureg)
    | dup |> std/io:print.ln("dup")
    | bad |> std/io:print.ln("bad:reg")

// SI and ext coexist: 3 kg priced at 2 USD carries both segments.
// (Mixed SI+ext juxtaposition inside one literal is not a surface;
// multiplication composes them.)
std/quantity:unit-reg-new(): r8
|> std/quantity:unit-reg-decls(reg: r8, source: "USD=axis(currency)")
    | exact ureg |> std/quantity:lit(3 kg)
        | exact k |> std/quantity:lit-x(2 USD, ureg)
            | exact q |> std/quantity:mul(a: k, b: q)
                | exact m |> std/quantity:render(n: m): t |> std/io:print.ln("{{ t:s }}") |> std/io:free(content: t) |> std/io:free(content: ureg)
                | mixed-cov |> std/io:print.ln("mc4") |> std/io:free(content: ureg)
                | sym-unc |> std/io:print.ln("su3") |> std/io:free(content: ureg)
                | bad e |> std/io:print.ln("b13") |> std/io:free(content: ureg)
            | undeclared-axis e |> std/io:print.ln("u12") |> std/io:free(content: e) |> std/io:free(content: ureg)
            | bad e |> std/io:print.ln("b14") |> std/io:free(content: e) |> std/io:free(content: ureg)
        | bad e |> std/io:print.ln("b15") |> std/io:free(content: ureg)
    | dup |> std/io:print.ln("dup")
    | bad |> std/io:print.ln("bad:reg")
