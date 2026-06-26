import std/io
import std/table

// Pin #6: prove a generated table is consumable at RUNTIME (the sieve's spine) —
// fold the wheel with the capture pattern over `for ! each`. The runtime sum must
// equal the comptime sum from 310_094: 30030*5760/2 = 86,486,400.
from(wheel) { x over 0..30030 | keep gcd(x, 30030) == 1 }

capture { acc: 0[i64] }
! as a |> for(wheel)
    ! each r |> captured { acc: a.acc + r }
| captured result |> std/io:print.ln("{{ result.acc:d }}")
