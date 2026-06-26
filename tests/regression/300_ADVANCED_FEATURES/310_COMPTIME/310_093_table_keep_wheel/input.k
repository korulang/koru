import std/io
import std/table

// Pin #2: `keep gcd(x,6)==1` -> the mod-6 wheel [1, 5], verified by its sum = 6.
from(wheel6) { x over 0..6 | keep gcd(x, 6) == 1 }
sum(total) { wheel6 }

std/io:print.ln("{{ total:d }}")
