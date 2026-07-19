// A multi-field record resumed ANONYMOUSLY through an effect arm: `-> { a, b }` is
// the record extension of the scalar resume `-> i64` (400_148), orthogonal to
// named continuation branches (400_135's `| result {…}` picks a tagged outcome).
// RULED: the arm's resume shape and continuation branches are different concepts —
// the handler hands back one record, the producer binds it and field-accesses. The
// single-field case collapses to the scalar (210_150); two fields is the legal record.
import std/io
pub event request { seed: i64 }
! ask -> { a: i64, b: i64 }
| done i64
request = ask(): c => done c.a + c.b + seed
request(seed: 8)
! ask -> { a: 10, b: 20 }
| done r |> std/io:print.ln("{{ r:d }}")
