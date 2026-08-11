// Pins `std/parser:generate` END TO END — the surface that had no suite
// coverage at all until now (its only check was challenges/backend-bakeoff,
// a challenge harness outside the board).
//
// This file is grammar ONLY: the `grammar` transform emits nothing, so the
// compile itself is a no-op program. The real assertion lives in post.sh,
// which re-invokes koruc with the `parser:generate` command, compiles the
// emitted parser with the host toolchain, and runs it against an oracle.
//
// What it guards: a Koru grammar becomes a STANDALONE parser in another
// language — no Koru runtime on the far side. That is the "ship it" half of
// the medium bed, and it must keep matching on values AND on error positions,
// which is the part that silently rots.
import std/parser

std/parser:grammar(nums)
! value v |> std/parser:match(v)
    | `-?[0-9]+` n -> n
    | array a -> a
! array a |> std/parser:match(a)
    | `\[` _ |> std/parser:sub(value): v |> std/parser:lit("]") -> v
