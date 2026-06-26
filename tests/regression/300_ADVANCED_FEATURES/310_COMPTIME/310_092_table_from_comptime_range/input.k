import std/io
import std/table

// Pin #1: generator-only comprehension -> const table, verified by its sum.
// `1..4` (upper-exclusive) = [1, 2, 3]; sum = 6.
from(nums) { x over 1..4 }
sum(total) { nums }

std/io:print.ln("{{ total:d }}")
