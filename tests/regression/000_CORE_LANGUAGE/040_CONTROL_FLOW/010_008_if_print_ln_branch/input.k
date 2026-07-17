// Cross-target `~if` whose branch bodies are `print.ln` — a comptime|transform
// event nested as a continuation body. Pins that the print family lowers to JS
// through its `|js` transform variant at a NESTED site, not only at top level:
// the JS emitter must splice the transform's `inv.inline_body` for the branch
// invocation, never emit a handler call against the rerouted `.impl` stub. The
// construct the playground default and self-contained `.k` programs reach for
// (Lars's repro); Zig and JS must produce byte-identical output.
import std/io

if(7 > 3)
| then |> std/io:print.ln("big")
| else |> std/io:print.ln("small")
