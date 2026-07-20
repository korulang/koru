// NESTING SWEEP — a user-defined multi-branch variant (found/missing, a
// record payload) DESTRUCTURED with a `when` guard, nested UNDER a for-each
// `! each` iteration body. Every construct in the sweep so far nests either
// a built-in obligation view (from-page's `ok s`, opaque, single-field) or a
// payload-less branch (if's then/else) under for-each — never a real,
// user-declared record-payload variant matched with `{ name, age }`
// destructure and a `when age > 40` guard, one level deep inside `! each`.
//
// Grounds: branch-payload destructure + when-guard on a real record-payload
// event — found/missing shape and the guard itself —
// 020_016_destructure_basic/input.kz:8-10,18 (`| found { name, age: i64 }
// when age > 40`); the `.k`-pure bare-name destructure form `{ a }` (no
// re-typed field) — 210_148_destructure_valid_fields/input.k:8,14
// (`| ok { a: i32, b: u8 }` declared, `| ok { a } |>` consumed); the event's
// OWN implementation dispatching via `if(...)` + `=>` branch construction,
// reading the event's own param directly (`if(n > 0)`) —
// 020_028_loop_exit_arrow_return/input.k:15-23 (`step = if(n > 0) | then =>
// more {...} | else => done acc`); for-each `! each i |> ... | done |> _`
// itself — 670_030_foreach_under_flow_head/input.k:7-9 (baseline, this same
// cluster). id=0,2 -> missing ("nope"); id=1 -> found{name:"lars",age:44},
// 44>40 so the guarded arm fires ("elder lars 44").
import std/io

event fetch { id: i64 }
| found { name: string, age: i64 }
| missing

fetch = if(id == 1)
| then => found { name: "lars", age: 44 }
| else => missing

for(0..3)
! each i |> fetch(id: @as(i64, @intCast(i)))
    | found { name, age } when age > 40 |> std/io:print.ln("elder {{ name:s }} {{ age:d }}")
    | found { name, age } |> std/io:print.ln("younger {{ name:s }} {{ age:d }}")
    | missing |> std/io:print.ln("nope")
| done |> _
