// PIN (outside-in finding, human-authored): a tor declared with a BARE RETURN
// (`-> string`) is implemented with the BRANCH CONSTRUCTOR form (`=>`). The
// frontend accepts it and the mismatch surfaces as a raw Zig error inside
// generated code:
//
//   output_emitted.zig:56:40: error: type '[]const u8' does not support
//   struct initialization syntax
//       break :blk .{ .response = .{ } };
//
// The author never wrote that file, that line, or that syntax. Nothing in the
// message names `=>`, `->`, or `validate-response`.
//
// The frontend holds both halves at parse time. From --ast-json on this file:
//   - the impl node is `{ branch_name: "response", fields: [], plain_value: null }`
//     — `response` was read as a BRANCH NAME with an empty payload
//   - the event_decl is `{ branches: [] }` with a `return_type` (ast.zig:1544
//     documents the pairing: "branch_name is empty; plain_value is the
//     expression … Pairs with EventDecl.return_type")
// A `=>` impl naming a branch on a tor that declares zero branches is decidable
// from those two facts alone. No flow analysis, no type inference.
//
// This is NOT the one-file-visibility limit — decl and impl are in the same file,
// so [[frag-frontend-checkers-see-one-file-not-the-program]] does not excuse it.
//
// The frontend ALREADY teaches the declaration-side twin of this confusion:
// PARSE003 rejects a single payload-carrying branch with "declare the single
// output as a bare return instead: `-> <type>`" (parser.zig:2322). The
// implementation-side mirror has no wall at all.
//
// The compiler also already OWNS the taxonomy it fails to check. KORU047, fired
// when an invoked event has no implementation, enumerates the four forms by name:
//   "Implement it with a proc (`~proc f|zig { ... }`), a bare-return impl
//    (`~f -> <value>`), a branch constructor (`~f => <branch> <value>`), or a
//    subflow (`~f = <flow>`)"
// So there is prose in-tree that distinguishes `->` from `=> <branch> <value>`
// and knows which is which. Note also that this pin's impl is `=> response` —
// a branch name with NO value, which does not match the `<branch> <value>` shape
// that message teaches either. Two independent grounds for rejection, one
// existing message that already articulates both, and no check.
//
// Siblings, same root, both also leaking raw Zig:
//   510_113 — branch decl, bare-return impl
//   510_114 — impl names a branch the decl does not declare
//
// EXPECT asserts only what is certain: the frontend must reject, and the message
// must not name a generated file. The wording of the eventual diagnostic is not
// invented here.
//
// Provenance: Lars changed `->` to `=>` on line 7 of
// koru-examples/human-doodle/doodle.k, 2026-07-30. His reading, which the AST
// confirms: "the tor needs singular satisfaction, and I am trying to do it with
// a branch."
import std/io

tor get-from-network {} -> string<tainted!>
get-from-network -> "Hello, World!"

tor validate-response { response: string<!tainted> } -> string
validate-response => response

get-from-network(): response
|> validate-response(response)
|> std/io:print.ln("From network: {{response:s}}")
