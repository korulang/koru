// PINS: the ROOT invocation of a store lifecycle arm body expands its comptime
// transform, the way every other position in the body already does.
//
// `! discharge` is the IN-FILE CONTROL. Its `print.ln` sits one link down a
// chain and prints, interpolation and all; the `! inserted` arm's `print.ln`
// sits at the body's root and vanishes. `std/io:print`/`print.ln` are
// `~[keyword|comptime|transform]` taking `expr: Expression` (io.kz:21/240), and
// where the rewrite does not happen the call lowers to the `print.impl` reroute
// those transforms declare for shape checking — silent, and indistinguishable at
// the source from an arm that ran.
//
// The boundary measured around this pin: a `source: Source` transform
// (`std/store:stored`) DOES expand at an arm root, and both kinds expand when
// chained. So this is not "interceptor bodies don't normalize" and not "root
// position is dead" — it is an Expression-taking transform in root position.
//
// Why it survived: no green interceptor test puts one there. 690_016/003/033
// root their arms at `std/store:stored`; 690_061/065 root theirs at an ordinary
// tor and chain the print behind it. This file is the uncovered corner.

import std/io
import std/store
import app/lib/src

std/store:new(batch, capacity: 2) { *app/lib/src:Src<live!> }
! inserted _ |> std/io:print.ln("arm inserted")
! discharge s |> app/lib/src:close(s): id |> std/io:print.ln("arm discharge {{ id:d }}")

std/io:print.ln("start")
app/lib/src:open(id: 9, work: 1): a |> std/store:insert(batch) { a }
| row _ |> std/io:print.ln("inserted")
| full f |> app/lib/src:close(s: f): id |> std/io:print.ln("full {{ id:d }}")
