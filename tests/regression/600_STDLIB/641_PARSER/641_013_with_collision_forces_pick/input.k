// Pins the AMBIGUITY-FORCES-PICK wall: when a bare name resolves against TWO
// active `[with]` regions that both own it, the resolver must REJECT and demand
// explicit qualification — never silently pick one. Both app/alpha and app/beta
// export `ping`; both are opened; a bare `ping` follows. Today the single-source
// resolver reads only the flow-head `[with]` (app/alpha) and SILENTLY resolves
// `ping` to alpha — the exact misparse the wall must replace. This pin flips to
// green when multi-source collection lands together with the collision
// diagnostic. (KORU140 is provisional — the code is assigned when the wall is
// built.)
import std/io
import app/alpha
import app/beta

[with]app/alpha:ping(msg: "seed"): s |> [with]app/beta:ping(msg: s): t |> ping(msg: t): u |> std/io:print.ln("picked={{ u:s }}")
