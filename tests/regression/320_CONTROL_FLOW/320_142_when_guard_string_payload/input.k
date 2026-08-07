// Pins: a call-site `when` guard comparing a STRING branch-payload field to
// a literal, on BOTH targets. The destructure + guard shape is 670_070's
// (`| found { name, age } when age > 40`) with the guard on the string
// field instead of the numeric one.
import std/io

tor fetch { id: i64 }
| found { name: string, age: i64 }
| missing

fetch = if(id == 1)
| then => found { name: "lars", age: 44 }
| else => missing

fetch(id: 1)
| found { name, age } when name == "lars" |> std/io:print.ln("match {{ age:d }}")
| found { name, age } |> std/io:print.ln("other {{ name:s }} {{ age:d }}")
| missing |> std/io:print.ln("nope")

fetch(id: 2)
| found { name, age } when name == "lars" |> std/io:print.ln("match {{ age:d }}")
| found { name, age } |> std/io:print.ln("other {{ name:s }} {{ age:d }}")
| missing |> std/io:print.ln("nope")
