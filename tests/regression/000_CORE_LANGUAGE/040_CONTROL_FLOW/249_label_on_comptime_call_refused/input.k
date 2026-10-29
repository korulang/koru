// PINS: a `#label` anchor declares a re-dispatch target — it can only wrap a
// call that exists at runtime. `std/io:print` is [keyword|comptime|transform]:
// the call is consumed at compile time, so the anchor emits no `repl:` block
// and `@repl` would dangle into Zig as `continue :repl` against a missing
// label (or declare the jump's args with AST-level types like `Expression`
// that do not exist at runtime). Refused with KORU211 at check time.
import std/io

tor t {}
| go
| stop

t => go

#repl std/io:print("tick\n") |> t()
| go |> @repl()
| stop |> _
