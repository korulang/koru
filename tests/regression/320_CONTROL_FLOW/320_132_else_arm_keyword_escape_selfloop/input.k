// Pins Zig-keyword escaping of branch payload binders on the self-loop
// weaver path. The shape: a self-recursive event whose body opens with a
// BIND (`same(x: n): k |>`) into an `if`, recursing under a `for`'s
// `| done` inside the `| else` arm. The weaver routes this body through
// the subflow self-loop and must emit the else-arm's binder discard as
// `_ = &@"else";` — the escaped spelling the branch capture itself
// already uses — never the raw keyword. (Without the leading bind, or
// without the for-hop, the body takes other emission paths that don't
// exhibit the discard at all.)
import std/io

pub event same { x: i64 } -> i64

same = if(x > 0)
| then -> x
| else -> x

pub event countdown { n: i64 } -> i64

countdown = same(x: n): k |> if(k == 0)
| then -> 0
| else |> for(0..1)
    ! each _ |> _
    | done |> countdown(n: k - 1): v -> v

countdown(n: 3): v |> std/io:print.ln("{{ v:d }}")
