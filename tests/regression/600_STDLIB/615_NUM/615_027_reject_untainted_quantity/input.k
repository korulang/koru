// PIN (enforcement): quantity:add demands <exact!>; a bare string
// holds no live obligation — phantom state mismatch.
import std/quantity

std/quantity:lit(s: "1 m")
| exact a |> std/quantity:add(a, b: "2 m")
    | exact r |> _
    | dim-mismatch |> _
| bad _ |> _
