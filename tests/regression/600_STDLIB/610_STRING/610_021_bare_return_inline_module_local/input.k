// PIN — bare-return inline at an EXTERNAL call site must lower `-> *String<instance!>`
// to a module-qualified Zig type (`*koru_std.koru_string.String`), not bare `*String`.
//
// Grounding: `take -> s` and `read -> s.data` in koru_std/string.kz (pure Koru
// identity/scalar impls). The tripwire is codegen (writeBareReturnType on the
// immediate-impl inline path), not the Koru surface — without the fix, Zig fails:
// `use of undeclared identifier 'String'` in main_module.
import std/string
import std/io

std/string:from-page(text: "hello")
| ok s |> std/string:take(s): owned |> std/string:read(s: owned): text |> std/io:print.ln("{{ text:s }}") |> std/string:free(s: owned)
| err _ |> _
