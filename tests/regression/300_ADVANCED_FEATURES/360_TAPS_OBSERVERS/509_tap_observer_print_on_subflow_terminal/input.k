// Pins: a tap observer using `std/io:print.ln` must emit its output when the
// tapped event is a SUBFLOW TERMINAL. `inc` is bare-returned by `run`, so the
// tap on `inc` fires in a terminal position; the observer prints "tapped".
// A mid-flow tap's `print.ln` lowers to a real stdout write (505 green); in this
// terminal context it lowers to the stub `print_impl_event.handler` (returns
// undefined, no output). This test guards that the observer's print reaches
// stdout. Sibling: 508 (mid-flow bare-return tap, green).
import std/io
import std/taps

tor inc { n: i32 } -> i32
inc -> n + 1

tor run { n: i32 } -> i32
run = inc(n): r -> r

tap(inc -> *): v |> std/io:print.ln("tapped")

run(n: 10): r |> std/io:print.ln("result: {{ r:d }}")
