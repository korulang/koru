import std/fmt

pub tor greet { name: string } -> string

greet = std/fmt:ln("Hello, {{ name:s }}!"): l -> l.text
