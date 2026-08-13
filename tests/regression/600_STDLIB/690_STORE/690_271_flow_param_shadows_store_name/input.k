// PINS: the 690_086 resolution-order ruleset — "bindings (innermost first) ->
// module-local stores -> `[global(name)]` stores" — applied to a FLOW'S OWN
// PARAMETERS, not just a continuation's row binding (690_090). A tor's
// parameter is a binding, and a punned argument naming it must stay the
// parameter: `~transit = reframe(goal, history)` must pass the CALLER's
// `history`, never rewrite it to a store cell that happens to share the name.
//
// MEASURED CAUSE (2026-08-13): create's whole-program store Walk seeds its
// bound-set with continuation bindings only, so a flow parameter named like a
// store got rewritten to `__koru_store_<name>.__koru_value` — the identity
// column of a store the flow never meant to touch. The store won on a missing
// shadow, not on a resolution rule: `transit = reframe(goal, history)` emitted
// `.history = __koru_store_history.__koru_value`, where Zig then errored on
// the array literal (a String cell) standing where the parameter belonged.
//
// Found by kopium-headless/headed.k: its `history` STORE and agent-body's
// `history` PARAMETER collided, and the flow-inlined build broke.
import std/io
import std/store
import std/string

std/store:new(history, capacity: 2) { *std/string:String<std/string:instance!> }

std/string:from-page(text: "SEEDED")
| ok a |> std/string:take(s: a): t |> std/store:insert(history) { t }
    | row _ |> _
    | full f |> std/string:free(s: f)
| err _ |> _

tor nop {}
tor nop-impl {}
proc nop-impl|zig {}
nop = nop-impl()

// The flow under test: its `history` PARAMETER shadows the store named
// `history`, so the punned argument below must not become a store read.
tor transit { goal: string, history: string } -> string
transit = reframe(goal, history)

tor reframe { goal: string, history: string } -> string
proc reframe|zig {
    return @import("std").fmt.allocPrint(@import("std").heap.page_allocator, "{s}|{s}", .{ history, goal }) catch @panic("OOM");
}

tor drive {}
drive = nop() |> std/store:query(history)
! query h |> std/string:read(s: h): thing |> transit(goal: "GOAL", history: thing): out |> std/io:print.ln("{{ out:s }}")

drive()
