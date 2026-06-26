import std/io
import std/table

// Pin #5: the mod-30030 wheel gap table (5,760 cyclic gaps). They tile exactly one
// period, so the full sum is the modulus: 30030. Strong check on the whole table.
gaps(g) { x over 0..30030 | keep gcd(x, 30030) == 1 }
sum(total) { g }

std/io:print.ln("{{ total:d }}")
