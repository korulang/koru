// The Barbour effect-typing arc's cornerstone form.
//
// An event's single payload-bearing output becomes an UNNAMED arrow return
// `-> T` instead of a redundant single named branch (`| doubled i32`). The
// arrow is the one-arm sugar of the same output grammar; >=2 outcomes still use
// named `|` arms. The call site binds the value with `-> d`, which then follows
// the ordinary obligation/scope system (an obligation-carrying return MUST be
// named to be dischargeable; a throwaway could bind `_`).
//
// Grounded baseline (existing today): `~name => ...` branch-constructor impl
// (020_014), `std/io:print.ln("{{ d:d }}")` (810 AoC). NEW (proposed): the
// `-> i32` on the event decl (output TYPE), the `~double -> a * 2` BARE-RETURN
// impl (`->` produces the value; `=>` stays the branch constructor), and the
// call-site `: d` BIND. The produce/consume duality: `->` produces a bare return
// (the twin of `=>`); `:` binds it at the call site (the twin of `|`/`!`). `:`
// is Koru's existing bind glyph (`a: 2`, `{ a: i32 }`) — no new symbol.
import std/io

pub tor double { a: i32 } -> i32
double -> a * 2

double(a: 21): d |> std/io:print.ln("{{ d:d }}")
