// TEST: fmt:ln basic - format a string and get it back via | line continuation
import std/fmt
import std/io

event greet { name: []const u8 } -> []const u8

greet = std/fmt:ln("Hello, {{ name:s }}!")
| line l -> l.text

greet(name: "World"): g |> std/io:print.ln(g)
