// PIN — bare-return inline at an EXTERNAL call site must lower `-> *String<instance!>`
// to a module-qualified Zig type (`*koru_std.koru_string.String`), not bare `*String`.
//
// Grounding: `take -> s` in koru_std/string.kz (pure Koru identity impl; its
// sibling `read -> s.data` retired under 610_007). The tripwire is codegen
// (writeBareReturnType on the immediate-impl inline path), not the Koru
// surface — without the fix, Zig fails:
// `use of undeclared identifier 'String'` in main_module.
import std/string
import std/io

std/string:from-page(text: "hello")
| ok s |> std/string:take(s): owned |> std/io:print.ln("{{ owned:S }}") |> std/string:free(s: owned)
| err _ |> _
