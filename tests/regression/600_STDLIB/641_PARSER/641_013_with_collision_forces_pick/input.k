// Pins the AMBIGUITY-FORCES-PICK wall (KORU140): when a bare name resolves
// against TWO active `[with]` regions that both own it, resolve-with-scopes must
// REJECT and demand explicit qualification — never silently pick one. Both
// app/alpha and app/beta export `ping`; both are opened; a bare `ping` follows,
// so it is owned by two vocabularies at once. The wall replaces the silent
// flow-head pick. `[with]` resolution is a metacircular pass (koru_std/
// compiler.kz), so its diagnostic surfaces at backend-exec — hence
// BACKEND_RUNTIME_ERROR, the same stage every other metacircular-analysis
// rejection reports at.
import std/io
import app/alpha
import app/beta

[with]app/alpha:ping(msg: "seed"): s |> [with]app/beta:ping(msg: s): t |> ping(msg: t): u |> std/io:print.ln("picked={{ u:s }}")
