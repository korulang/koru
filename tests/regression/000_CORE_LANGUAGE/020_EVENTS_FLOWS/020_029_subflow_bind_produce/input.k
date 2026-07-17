// A single-output subflow whose body binds a sub-call's bare result and
// PRODUCES it as the event's `-> T` return: `call(args): bind -> produce`.
// This is the produce-arm twin of `call(args): bind => ok 64` (the construct
// arm that satisfies a continuation-branch decl). Both must work.
//
// Pins a parser bug: an over-broad PARSE001 guard in parseEventInvocation
// rejected ALL top-level `->` in an invocation line, killing the produce arm.
import std/io

pub event a { x: i64 } -> i64
a -> x + 1

pub event combo { x: i64 } -> i64
combo = a(x): r -> r

combo(x: 5): out |> std/io:print.ln("{{ out:d }}")
