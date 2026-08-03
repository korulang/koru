// PINS: a unary minus in front of a row reference, and the kebab name that
// must NOT be broken by allowing it.
//
// Kebab-case makes `-` an IDENTIFIER character, so every text rewriter's
// left-boundary test — "the byte before is not an identifier char" — reads
// `-r.v` as the interior of a name like `foo-r` and declines to rewrite. The
// reference then reached the host verbatim as `-r.v`, where `r` does not
// exist: a generated-code error naming a Koru binding, raised against a
// program that is correct Koru.
//
// The only spelling that worked was `- r.v`, WITH A SPACE. Whitespace carries
// no meaning inside an expression in this language, so an author has no reason
// to suspect it and no way to find it.
//
// The disambiguation is local and total, and both halves are pinned here
// because a fix to either one alone is wrong:
//
//   - a `-` belongs to an identifier only when it sits BETWEEN two identifier
//     characters, so `-r.v` and `2 * -r.v` both read the column;
//   - `twice-r` is ONE name. Its trailing `r` is preceded by `-`, which is
//     preceded by `e`, so it must stay untouched. A fix that simply treated
//     every `-` as a boundary would rewrite it into the column read and break
//     every kebab name whose last segment collides with a row binding.
//     It is called as a CHAIN STEP: a tor call inside an envelope value is not
//     a spelling the store lowers, and reaches the host verbatim.
//
// Found by the ECS benchmark's bevy_strength_world port, whose bounce arm
// writes `-d.vx * 0.8` — the plainest way anyone would spell a reflection.
import std/io
import std/store

std/store:new(cells, capacity: 3) { v: i64 }

tor twice-r { x: i64 } -> i64
twice-r -> x * 2

std/store:insert(cells) { v: 5 }
std/store:insert(cells) { v: -3 }

std/store:query(cells)
! query r |> std/store:stored { r.v: -r.v * 2 }

std/store:query(cells)
! query r |> std/store:stored { r.v: 2 * -r.v }

std/store:query(cells)
! query r |> twice-r(x: r.v): d |> std/store:stored { r.v: d }

std/store:query(cells)
! query r |> std/io:print.ln("v {{ r.v:d }}")
