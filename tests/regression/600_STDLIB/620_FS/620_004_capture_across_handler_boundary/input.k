// RED PIN (found by the composition burn-test, 2026-06-12): captured { }
// writes inside a RUNTIME event's effect handler cannot reach the capture
// cell. The ! line handler lowers to a synthesized Handlers struct — a Zig
// namespace boundary — while the cell is a function-local `var` outside it:
// "mutable 'acc' not accessible from here ... crosses namespace boundary".
// Templates (for/if) splice handlers into the SAME scope, which is why every
// AoC day works; runtime-effect handlers don't. Goes green when effect-
// handler lowering gains a way to carry flow-local state (instance handlers
// with a cell pointer, or scope-spliced lowering for in-flow handlers).
// THIS SHAPE IS THE REAL-INPUT ACCUMULATOR — file → lines → match → cell —
// so it blocks the pristine real-input form of every counting day.

import std/io
import std/fs
import std/regex

capture { hits: 0[i64] }
! as acc |> std/fs:read-lines(path: "tests/regression/600_STDLIB/620_FS/620_004_capture_across_handler_boundary/input.txt")
    ! line l |> std/regex:match(l)
        | `[0-9]+` _ |> captured { hits: acc.hits + 1 }
        | no-match |> _
    | done _ |> _
    | failed e |> std/io:print.ln("FAILED: {{ e:s }}")
| captured total |> std/io:print.ln("{{ total.hits:d }} number lines")
