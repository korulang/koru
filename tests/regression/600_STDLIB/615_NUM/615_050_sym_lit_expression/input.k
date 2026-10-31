import std/io
import std/sym

// lit's Expression field: the arg's source text is captured, not evaluated.
// lit(expr: E), bare lit(E), and lit("E") must land on the same canon.
// Runtime strings go through std/sym:ingest + std/sym:parse, not lit.

std/sym:lit(expr: inv((1e0+(-1e0*x))))
| exact a |> std/io:print.ln("{{ a:s }}") |> std/sym:free(n: a)
| bad |> std/io:print.ln("bad-literal-expr")

std/sym:lit(√(2e0)+π)
| exact b |> std/io:print.ln("{{ b:s }}") |> std/sym:free(n: b)
| bad |> std/io:print.ln("bad-literal-bare-expr")

std/sym:lit(inv((1e0+(-1e0*x))))
| exact c |> std/sym:deriv(a: c): dc
    |> std/io:print.ln("{{ dc:s }}") |> std/sym:free(n: dc)
| bad |> std/io:print.ln("bad-literal-bare-expr-deriv")

std/sym:lit(expr: inv((1e0+(-1e0*x))))
| exact d |> std/sym:deriv(a: d): dd
    |> std/io:print.ln("{{ dd:s }}") |> std/sym:free(n: dd)
| bad |> std/io:print.ln("bad-literal-expr-deriv")

// verbatim capture means a malformed sexpr still refuses at runtime —
// quoting is capture, not compile-time validation.
std/sym:lit(expr: 1e0+*x)
| exact e |> std/io:print.ln("{{ e:s }}") |> std/sym:free(n: e)
| bad |> std/io:print.ln("bad-literal-malformed")

// an unlabeled string literal binds expr too — quotes captured, unquoted
// in the proc — and lands on the same canon as the bare spelling.
std/sym:lit("2*π")
| exact f |> std/io:print.ln("{{ f:s }}") |> std/sym:free(n: f)
| bad |> std/io:print.ln("bad-literal-string-literal")
