// Proto declared through the DEFAULT DOOR: `std/proto(Engine)` — the module
// path IS the verb (the default-event rule rewrites a bare module call into
// `std/proto:default(Engine)` at import time; import_pipeline.zig
// rewriteDefaultEventCalls). The full slice holds: std/list:new over the
// entry synthesizes the six op events (new/push/len/get/pop/free) exactly as
// the std/types:proto door does (660_028) — same registry, same erased
// marker, same container. 660_030 guards the second door's registration:
// the checker/type-registry scans must see `std/proto:default(Engine)` as a
// proto entry (phantom_semantic_checker.zig, type_registry.zig —
// proto_door rung 2026-09-03), or the duplicate wall and the nominal-
// distinctness gate go silent for it.
import std/io
import std/proto
import std/list

std/proto(Engine) {
    rpm: i32
    serial: string
}

std/list:new(Engine)
| list xs |> std/list:push(xs, v: 10) |> std/list:push(xs, v: 20) |> std/list:len(xs): n |> std/io:print.ln("len={{ n:d }}") |> std/list:pop(xs)
    | item v |> std/io:print.ln("popped {{ v:d }}") |> std/list:free(xs)
    | empty  |> std/io:print.ln("EMPTY") |> std/list:free(xs)
| err e |> std/io:print.ln("ERR {{ e:s }}")