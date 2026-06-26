import std/io
import std/table

// Pin #4: the wheel GAP table — cyclic residue differences a wheel sieve walks.
// mod-6 wheel residues [1,5] over period 6 -> gaps [4, 2]. The k gaps tile one
// full turn, so they sum to the period (6). Verified by sum.
gaps(g6) { x over 0..6 | keep gcd(x, 6) == 1 }
sum(total) { g6 }

std/io:print.ln("{{ total:d }}")
