// A mid-pipe `: name` bind inside a store-watch arm must be legal.
//
// Transplant-purity (690_006, thesis T1) says a watch body may reference
// only its own branch bindings and comptime-known names, because the body
// is spliced to the store's WRITE SITES, not run at its lexical position.
// A `: name` bound by an EARLIER step of the SAME arm is a branch-local
// binding: it is produced inside the body and travels with it to every
// write site. It is not "runtime state of the enclosing flow".
//
// Twin of 620_002 (`fmt:ln(): l |> sink(l.text)` at top level, GREEN),
// lifted one composition level deeper — inside a watch arm. The purity
// check seeds its `allowed` set from the arm-head payload binding (`c`)
// only and never harvests the mid-chain pipe bind (`l`, carried on
// `invocation.return_binding`), so before the fix it flagged `l` as an
// ambient reference. The fix threads pipe-bind scope down the chain.
//
// 690_006 stays RED for the right reason: there `ctx` is bound OUTSIDE the
// arm (in the enclosing flow, before the watch), so no step within the arm
// introduces it — still correctly rejected.

import std/io
import std/fmt
import std/store

std/store:new(counter) { clicks: 0[i64] }

std/store:watch(counter)
! clicks c |> std/fmt:ln("clicked {{ c:d }} times"): l |> std/io:print.ln(l.text)

std/store:stored { counter.clicks: counter.clicks + 1 }
std/store:stored { counter.clicks: counter.clicks + 1 }
