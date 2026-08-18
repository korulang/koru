// TEST: fmt:ln basic — format a string and bind the result with `: l`.
import std/fmt
import std/io

tor greet { name: string } -> string

greet = std/fmt:ln("Hello, {{ name:s }}!"): l -> l.text

greet(name: "World"): g |> std/io:print.ln(g)
