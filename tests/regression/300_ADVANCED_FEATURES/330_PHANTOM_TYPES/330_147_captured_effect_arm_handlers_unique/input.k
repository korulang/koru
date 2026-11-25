// 330_147 — two subflow effect-arms that each capture an outer binding
// synthesize DISTINCT `__HandlersCaps_*` structs for the effect invocation.
//
// `read(s)` produces `! text` + `| done` — an effect event. Invoked inside a
// continuation arm whose `! text` body captures an outer binding (`page`,
// passed to `use-it`), the emitter synthesizes a Handlers struct carrying the
// capture. Two such arms in one module each need a unique name — a fixed
// `Handlers_sf` collided as a duplicate struct member in emitted Zig.
//
// What this pins: per-subflow effect-arm handler names are module-unique, so
// N captured effect invocations coexist. Guards the visitor_emitter
// subflow-head Handlers naming.
import std/string
import std/io
import std/store

std/store:new(buf, capacity: 2) { *std/string:String<instance!> }
std/store:new(ui) { page: 0[i64] }

std/string:from-page(text: "")
| ok a |> std/string:take(s: a): text |> std/store:insert(buf) { text }
    | row _ |> _
    | full f |> std/string:free(s: f)
| err _ |> _

tor page-route { page: i64 }
| ?text-input
| ?textarea
| ?style

page-route = cond(page)
| c p when p == 0 => text-input
| c p when p == 1 => textarea
| c _ => style

tor use-it { a: i64, b: string }
use-it = std/io:print.ln("{{ b:s }} {{ a:d }}")

tor exhibit { page: i64 }
exhibit = page-route(page)
| text-input |> std/store:query(buf)
    ! query b1 |> std/string:read(s: b1)
        ! text t1 |> use-it(a: page, b: t1)
        | done n1 |> _
| textarea |> std/store:query(buf)
    ! query b2 |> std/string:read(s: b2)
        ! text t2 |> use-it(a: page, b: t2)
        | done n2 |> _

exhibit(ui.page)
