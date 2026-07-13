// Pins MULTI-SOURCE `[with]` resolution: two `[with]` regions in one subtree,
// each opening a different module, both consulted for otherwise-unresolved bare
// names. `ping-a` lives only in app/alpha, `ping-b` only in app/beta. Neither
// `[with]` sits at the flow head, so this stays RED until the resolver collects
// `[with]` targets from EVERY annotated step in the subtree (mid-chain included,
// now that the parser captures them) rather than only the flow head. The values
// thread through so every bind is consumed.
import std/io
import app/alpha
import app/beta

std/io:print.ln("start") |> [with]app/alpha:ping-a(msg: "seed"): s |> [with]app/beta:ping-b(msg: s): t |> ping-a(msg: t): u |> ping-b(msg: u): v |> std/io:print.ln("resolved={{ v:s }}")
