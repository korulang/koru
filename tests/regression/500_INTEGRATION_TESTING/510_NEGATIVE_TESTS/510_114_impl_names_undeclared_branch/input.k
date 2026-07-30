// PIN: the impl constructs a branch the declaration does not declare. The tor
// declares `| ok` and `| err`; the impl produces `=> nope "hi"`. Accepted by the
// frontend, leaks raw Zig:
//
//   output_emitted.zig:45:28: error: no field named 'nope' in union
//   'output_emitted.main_module.get_input_event.Output'
//
// This is the shallowest member of the 510_112 family and the strongest argument
// that the family shares one missing wall rather than three. "The name you
// produced is not one of the names you declared" is a set membership test over
// `EventDecl.branches` — the check needs no types, no flow, no inference, and
// both sides sit in the same file. Zig ends up performing it, against a union it
// synthesised, and reports it against a file the author never opened.
//
// Note what the Zig message does contain: the branch name `nope` and, encoded in
// the union's mangled path, the tor name. So the information needed for a good
// diagnostic is present at the point of failure — it is being reported by the
// wrong layer, in the wrong vocabulary, at the wrong source location.
//
// Compare 510_090 (unknown label `@missing`): also a backend-stage rejection, but
// its message is in KORU's OWN vocabulary — "unknown label '@missing'" names the
// thing the author wrote. So the contrast here is not merely about which stage
// catches it; it is that this position reports in Zig's vocabulary about Zig's
// synthesised types. A backend-stage error can still be a koru diagnostic.
//
// EXPECT asserts only what is certain: the frontend must reject, and the message
// must not name a generated file.
import std/io

tor get-input {}
| ok string
| err string

get-input => nope "hi"

get-input()
| ok s |> std/io:print.ln(s)
| err _ |> _
