// MINIMAL ISOLATE: produce-of-call discards the callee result.
// `| then -> id(x)` emits `_ = id_event.handler(...)` — the returned value is
// dropped, then zig rejects the handler for implicit-return (non-void body
// falls off the end). Bind-then-produce (`: r -> r`) works; produce-of-call
// should emit `return handler(...)`.
import std/io

pub tor id { x: i64 } -> i64
id -> x + 1

pub tor wrap { x: i64 } -> i64
wrap = if(x > 0)
| then -> id(x)
| else -> 0

wrap(x: 3): r |> std/io:print.ln("{{ r:d }}")
