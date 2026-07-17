// Test: Pure subflow implementation (no proc needed)
// From the README example - this is idiomatic Koru
// This is the default authoring model for ordinary event behavior.
import std/io

event greet { name: string } -> string

greet -> "Hello, " ++ name ++ "!"

greet (name: "World"): msg |> std/io:print.ln(msg)
