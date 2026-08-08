// PINS A HOLE, RED BY DESIGN. A templated write nested inside an `if` arm is
// NOT lowered, and ships the raw template as the row's text — the same silent
// corruption class 690_267 closed for plain literals, reappearing one level in.
//
// 690_268's write sits directly in the rule arm and lowers correctly. This one
// differs only by the `if`, and that is the whole cause: `if`/`for` are
// template procs that FREEZE their rendered body into `inline_body` before the
// store's walk runs (the freeze 690_074 pins). The walk rewrites row
// references inside that frozen text, but the template lowering only ever sees
// a stored invocation's own argument — so the write inside the arm keeps its
// `{{ … }}` and the emitted output carries a host cell read spliced into what
// the program stores.
//
// Found by the DOM gauntlet's conformance check rather than by any test here:
// the vehicle marks a row inside `if(op.code == 4)`, and the row's text came
// back reading `{{ (&__koru_store_rows.label)[…`. Worth stating because it is
// the second time a check outside this suite has caught a text-substitution
// defect this suite could not see.
//
// GOES GREEN when the lowering reaches frozen bodies, or — the floor, and
// correct on its own — when the store REFUSES a `{{ … }}` that survives into
// an emitted write, rather than shipping it. Corruption is never the right
// answer to "not implemented here".
import std/io
import std/store

std/store:new(flag) { on: 1[i64] }

std/store:new(rows, capacity: 4) { label: char[40] }

std/store:insert(rows) { label: "pony" }
    | row _ |> _
    | full |> _

std/store:rule(rows)
! row e |> if(flag.on == 1)
    | then |> std/store:stored { e.label: "{{ e.label:s }} !!!" }
    | else |> _

std/store:query(rows)
! query e2 |> std/io:print.ln("{{ e2.label:s }}")
