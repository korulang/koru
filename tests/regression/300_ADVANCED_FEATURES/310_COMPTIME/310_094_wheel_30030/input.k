import std/io
import std/table

// Pin #3: the mod-30030 champion wheel (5,760 residues), verified by its FULL sum.
// Residues coprime to n in [0,n) pair as r and n-r, so sum = n*phi(n)/2 =
// 30030*5760/2 = 86,486,400. This validates every residue, not just the count.
from(wheel30030) { x over 0..30030 | keep gcd(x, 30030) == 1 }
sum(total) { wheel30030 }

std/io:print.ln("{{ total:d }}")
