// 340_015 — an UNBOUND `! each` inside `! construct`: the traversal's loop
// variable falls back to its default name, `__it`.
//
// 340_010 is the bound face of this same shape — `! each x |> push(x)`, where
// the binding names the loop variable and the emitted comptime `for` captures
// it under that name. When the arm carries NO binding, the constructor
// transform still has to emit a capture (a Zig `for` over a range has one), so
// it emits the default `__it` (constructor.kz:93), and the same name types the
// element probe that infers `__E` from the push expression.
//
// The default is therefore NOT anonymity: an unbound `! each` that ignores the
// loop variable does not compile, because Zig rejects both the unused capture
// and the unused probe constant, and a push of a bare literal additionally
// yields a `[]const comptime_int` the `| constructed` traversal cannot index at
// runtime. The only program the default admits is one that spells `__it`, which
// is what this pins — the fallback name is part of the surface, not an internal
// placeholder.
//
// Output is 340_010's, byte for byte: same range, same elements, only the
// spelling of the loop variable differs.

import std/io
import std/constructor

std/constructor(nums)
! construct |> for(1..4)
    ! each |> std/constructor:push(__it)
| constructed built |> for(built)
    ! each n |> std/io:print.ln("n={{ n:d }}")
