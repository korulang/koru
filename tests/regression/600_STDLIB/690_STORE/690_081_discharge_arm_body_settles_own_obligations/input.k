// PINS: a `! discharge` arm is ORDINARY KORU, so obligations its own body
// creates settle by the ordinary rules.
//
// The arm exists because the store cannot dispose this column unattended:
// `abandon` is the only exit from <live!> and it RETURNS a *Bin<owned!>, so
// there is nobody at a teardown to take it. That is precisely why the author
// gets to write the body — and a body is a chain, not a single call.
//
// Here `abandon(item.j)` hands back a Bin. `bin.close` is its one void
// terminal, so auto-discharge settles it exactly as it would anywhere else in
// the program. Nothing about sitting inside `! discharge` should change that.
//
// 690_057 is the sibling and does NOT cover this: its arm is `commit(item.tx)`,
// a single void call with no intermediate obligation, so the one-step case is
// all the arm has ever been asked to do.
//
// Found building koru-examples/downloads, a TUI over curl's non-blocking
// `drain`, where the arm has to read `cancel(item.p) |> multi.close(...)` for
// exactly this reason.
import std/io
import std/store
import app/lib/job

std/store:new(jobs, capacity: 4) { j: *app/lib/job:Job<live!> }
! discharge item |> app/lib/job:abandon(item.j)

app/lib/job:start(): j1 |> std/store:insert(jobs) { j: j1 }
    | row _ |> std/io:print.ln("inserted")
