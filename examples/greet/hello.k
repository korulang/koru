// README hello — same shape as 020_014_pure_subflow_impl.
import std/io

tor greet { name: string } -> string

greet -> "Hello, " ++ name ++ "!"

greet (name: "World"): msg |> std/io:print.ln(msg)
