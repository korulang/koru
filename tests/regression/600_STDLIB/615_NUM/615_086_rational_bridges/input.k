// std/rational bridges: Dec<->rat, rat<->sym text, and Wang rational
// reconstruction (the Dixon-lift recovery kernel).
import std/io
import std/num
import std/sym
import std/rational

// dec-of-rat: truncated to prec significant digits (the num:div law).
std/rational:lit(s: "1/3")
| exact a |> std/rational:dec-of-rat(a, prec: 8)
    | exact d |> std/io:print.ln("{{ d:s }}") |> std/num:free(n: d)
    | bad |> std/io:print.ln("bad-prec")
| bad x |> std/io:print.ln("bad-lit")

// dec-of-rat-exact: terminating denominators render exactly; 1/3 names
// |nonterminating rather than silently approximating.
std/rational:lit(s: "1/4")
| exact a |> std/rational:dec-of-rat-exact(a)
    | exact d |> std/io:print.ln("{{ d:s }}") |> std/num:free(n: d)
    | nonterminating |> std/io:print.ln("nonterm")
| bad x |> std/io:print.ln("bad-lit")

std/rational:lit(s: "1/3")
| exact a |> std/rational:dec-of-rat-exact(a)
    | exact d |> std/io:print.ln("{{ d:s }}") |> std/num:free(n: d)
    | nonterminating |> std/io:print.ln("nonterm")
| bad x |> std/io:print.ln("bad-lit")

// rat-of-dec: every decimal is rational — exact.
std/num:lit(s: "1.25")
| exact a |> std/rational:rat-of-dec(a): r |> std/rational:render(n: r): t |> std/io:print.ln("{{ t:s }}") |> std/io:free(content: t)
| bad x |> std/io:print.ln("bad-lit")

// sym-of-rat: canon text — inv(d) for unit numerators, (n*inv(d)) else,
// decimals for {2,5} denominators.
std/rational:lit(s: "2/3")
| exact a |> std/rational:sym-of-rat(a): t |> std/io:print.ln("{{ t:s }}") |> std/io:free(content: t)
| bad x |> std/io:print.ln("bad-lit")

std/rational:lit(s: "1/15")
| exact a |> std/rational:sym-of-rat(a): t |> std/io:print.ln("{{ t:s }}") |> std/io:free(content: t)
| bad x |> std/io:print.ln("bad-lit")

std/rational:lit(s: "-4/7")
| exact a |> std/rational:sym-of-rat(a): t |> std/io:print.ln("{{ t:s }}") |> std/io:free(content: t)
| bad x |> std/io:print.ln("bad-lit")

// rat-of-sym: dec | inv(dec) | (dec*inv(dec)) — non-rational shapes |bad.
std/sym:lit((7e0*inv(1.1e1)))
| exact sx |> std/rational:rat-of-sym(s: sx)
    | exact r |> std/rational:render(n: r): t |> std/io:print.ln("{{ t:s }}") |> std/io:free(content: t)
    | bad x |> std/io:print.ln("bad-sym") |> std/io:free(content: x)
| bad |> std/io:print.ln("bad-symlit")

std/sym:lit(inv(2e0))
| exact sx |> std/rational:rat-of-sym(s: sx)
    | exact r |> std/rational:render(n: r): t |> std/io:print.ln("{{ t:s }}") |> std/io:free(content: t)
    | bad x |> std/io:print.ln("bad-sym") |> std/io:free(content: x)
| bad |> std/io:print.ln("bad-symlit")

std/sym:lit(5e-1)
| exact sx |> std/rational:rat-of-sym(s: sx)
    | exact r |> std/rational:render(n: r): t |> std/io:print.ln("{{ t:s }}") |> std/io:free(content: t)
    | bad x |> std/io:print.ln("bad-sym") |> std/io:free(content: x)
| bad |> std/io:print.ln("bad-symlit")

std/sym:lit((x+1e0))
| exact sx |> std/rational:rat-of-sym(s: sx)
    | exact r |> std/rational:render(n: r): t |> std/io:print.ln("{{ t:s }}") |> std/io:free(content: t)
    | bad x |> std/io:print.ln("bad-sym") |> std/io:free(content: x)
| bad |> std/io:print.ln("bad-symlit")

// rat-recon: 5*inv(7) == 70 (mod 97) reconstructs 5/7 inside bound 10;
// bound 6 excludes the denominator and names |none.
std/num:lit(s: "70")
| exact rr |> std/num:lit(s: "97")
    | exact mm |> std/num:lit(s: "10")
        | exact bb |> std/rational:rat-recon(r: rr, m: mm, bound: bb)
            | exact v |> std/rational:render(n: v): t |> std/io:print.ln("{{ t:s }}") |> std/io:free(content: t)
            | none |> std/io:print.ln("none")
            | bad |> std/io:print.ln("bad-recon")
        | bad z |> std/io:print.ln("bad-lit")
    | bad y |> std/io:print.ln("bad-lit")
| bad x |> std/io:print.ln("bad-lit")

std/num:lit(s: "70")
| exact rr |> std/num:lit(s: "97")
    | exact mm |> std/num:lit(s: "6")
        | exact bb |> std/rational:rat-recon(r: rr, m: mm, bound: bb)
            | exact v |> std/rational:render(n: v): t |> std/io:print.ln("{{ t:s }}") |> std/io:free(content: t)
            | none |> std/io:print.ln("none")
            | bad |> std/io:print.ln("bad-recon")
        | bad z |> std/io:print.ln("bad-lit")
    | bad y |> std/io:print.ln("bad-lit")
| bad x |> std/io:print.ln("bad-lit")
