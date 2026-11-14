// std/quantity: unitreg — declared non-SI axes. Dim = [7]i32 never
// widens; money/energy/custom live as unitreg:v1 registry entries,
// name or name=axis(kind), and undeclared atoms refuse by name.
import std/io
import std/quantity

// money: declare axes in one block
std/quantity:unit-reg-new(): r0
|> std/quantity:unit-reg-decls(reg: r0, source: "USD=axis(currency);EUR=axis(currency);point")
    | exact r |> std/io:print.ln("{{ r:s }}") |> std/io:free(content: r)
    | dup |> std/io:print.ln("dup")
    | bad |> std/io:print.ln("bad")

// get: kind lookup, undeclared refuses
std/quantity:unit-reg-new(): g0
|> std/quantity:unit-reg-decls(reg: g0, source: "USD=axis(currency)")
    | exact g1 |> std/quantity:unit-reg-get(reg: g1, name: "USD")
        | exact k |> std/io:print.ln("kind:{{ k:s }}") |> std/io:free(content: k) |> std/io:free(content: g1)
        | undeclared-axis |> std/io:print.ln("ua") |> std/io:free(content: g1)
        | bad |> std/io:print.ln("g:bad") |> std/io:free(content: g1)
    | dup |> std/io:print.ln("g1:dup")
    | bad |> std/io:print.ln("g1:bad")

std/quantity:unit-reg-new(): h0
|> std/quantity:unit-reg-decls(reg: h0, source: "USD=axis(currency)")
    | exact h1 |> std/quantity:unit-reg-get(reg: h1, name: "JPY")
        | exact k |> std/io:print.ln("kind:{{ k:s }}") |> std/io:free(content: k) |> std/io:free(content: h1)
        | undeclared-axis |> std/io:print.ln("undeclared-axis") |> std/io:free(content: h1)
        | bad |> std/io:print.ln("h:bad") |> std/io:free(content: h1)
    | dup |> std/io:print.ln("h1:dup")
    | bad |> std/io:print.ln("h1:bad")

// merge via unitreg:v1 text + put one + dup arm
std/quantity:unit-reg-new(): m0
|> std/quantity:unit-reg-decls(reg: m0, source: "USD")
    | exact m1 |> std/quantity:unit-reg-put(reg: m1, name: "EUR", kind: "currency")
        | exact m2 |> std/quantity:unit-reg-decls(reg: m2, source: "unitreg:v1;JPY=axis(currency)")
            | exact m3 |> std/io:print.ln("{{ m3:s }}") |> std/io:free(content: m3)
            | dup |> std/io:print.ln("m3:dup")
            | bad |> std/io:print.ln("m3:bad")
        | dup |> std/io:print.ln("m2:dup")
        | bad |> std/io:print.ln("m2:bad")
    | dup |> std/io:print.ln("m1:dup")
    | bad |> std/io:print.ln("m1:bad")

std/quantity:unit-reg-new(): d0
|> std/quantity:unit-reg-decls(reg: d0, source: "USD;USD")
    | exact r |> std/io:print.ln("dup?") |> std/io:free(content: r)
    | dup |> std/io:print.ln("dup")
    | bad |> std/io:print.ln("bad")

// malformed: bad axis rhs and bad name
std/quantity:unit-reg-new(): b0
|> std/quantity:unit-reg-decls(reg: b0, source: "USD=money")
    | exact r |> std/io:print.ln("bad?") |> std/io:free(content: r)
    | dup |> std/io:print.ln("dup")
    | bad |> std/io:print.ln("bad")
