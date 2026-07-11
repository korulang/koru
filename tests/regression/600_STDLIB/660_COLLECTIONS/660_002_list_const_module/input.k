// RED PIN — module-scope list declaration (growable). PROPOSED, unbuilt.
//
// const-block declares a typed module-scope binding; std/list[i64] delegates
// codegen to the std/list library. `[i64]` echoes const's own `42[i32]`.
// push is VOID (chains `|>`, grounded by 810_071 print.ln |> query). Module-scope
// mutable state = the global category Koru has never had.
import std/io
import std/list

const {
  xs: std/list[i64]
}

std/list:push(xs, v: 3) |> std/io:print.ln("{{ xs.len:d }}")
