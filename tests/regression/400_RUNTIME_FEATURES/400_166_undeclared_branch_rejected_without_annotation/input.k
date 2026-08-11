// The guard side of the undeclared-branch direction: WITHOUT `[prototype]`,
// handling a branch the event does not declare is a hard KORU021 error. This
// is byte-for-byte the source of 400_165 with the annotation removed: there
// the `| soon` arm is tolerated and pruned; here it must be rejected.
//
// This pins that declaration-debt cannot leak into ordinary code: the
// handled-but-undeclared arm slides ONLY under the greppable in-source
// annotation, never by default.

import std/io

pub tor run {}
| done
| err string

run => err "declared path ran"

run()
| done |> std/io:print.ln("done ran")
| err msg |> std/io:print.ln(msg)
| soon |> std/io:print.ln("undeclared arm — must be KORU021 without [prototype]")
