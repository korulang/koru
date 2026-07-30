// PIN: the mirror of 510_112. A tor declaring TWO branches (`| ok` / `| err`)
// is implemented with the BARE RETURN form (`->`). Accepted by the frontend,
// leaks raw Zig:
//
//   output_emitted.zig:45:24: error: expected type
//   'output_emitted.main_module.get_input_event.Output', found '*const [2:0]u8'
//
// Written as its own test rather than a case inside 510_112 because the two
// directions are checked by different reach, and the pair is the diagnostic: if
// one goes green while the other stays red, the fix covered one direction of the
// impl/decl disagreement and not the other.
//
// Two branches, not one, on purpose. A single payload-carrying branch is already
// rejected at the DECLARATION by PARSE003 ("declare the single output as a bare
// return instead") — which masks this case entirely at one branch and is why the
// obvious minimal spelling of this test cannot reach the bug.
//
// EXPECT asserts only what is certain: the frontend must reject, and the message
// must not name a generated file.
import std/io

tor get-input {}
| ok string
| err string

get-input -> "hi"

get-input()
| ok s |> std/io:print.ln(s)
| err _ |> _
