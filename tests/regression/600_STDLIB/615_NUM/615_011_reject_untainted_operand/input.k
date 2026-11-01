// PIN (enforcement): add demands <exact!>; a bare string literal
// holds no live obligation — phantom state mismatch.
import std/num

std/num:lit { 1 }
| exact a |> std/num:add(a, b: "3")
| bad _ |> _
