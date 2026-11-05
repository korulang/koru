// A wildcard-payload arm binding (`! as g` on capture — the arm's payload
// is `*`) cannot be typed by lookupBranch, so it cannot cross a store
// sweep boundary. Before the bind was collected at all, a body that read
// it dropped through and the emitted Zig died `use of undeclared
// identifier` — the pin holds the named refusal that replaced the hole.
import std/io
import std/store

std/store:new(spec, capacity: 8) { d: i64 }
std/store:insert(spec) { d: 10 }

capture { items: [_]i64{ 10, 20 } }
! as g |> std/store:query(spec)
    ! query s
        |> std/io:print.ln("{{ g.items:s }}")
