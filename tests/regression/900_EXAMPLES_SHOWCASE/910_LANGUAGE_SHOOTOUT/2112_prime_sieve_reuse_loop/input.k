// GREEN (2026-06-28): the `faithful=no` REUSE sieve — and the language capability
// that makes it expressible: threading a FOREIGN module's owned resource through a
// user-defined looping flow as a BORROW parameter.
//
// The field is allocated ONCE (`std/field:new`), passed into the label-fold loop
// `run` as a borrow param (`f: *Field<std/field:field>`), and `clear`ed + re-marked
// each pass instead of re-allocated. That is the drag-race `faithful=no` shape
// (reuse the buffer; contrast 2111 which re-allocates per pass = `faithful=yes`).
//
// THE CAPABILITY THIS PINS (phantom_semantic_checker.zig): a user event can take a
// foreign type's resource as a borrow param, written with the EXPLICIT module-
// qualified phantom `*Field<std/field:field>` (the slash canon, KORU035). Three
// pieces had to land together:
//   1. the qualified phantom resolves cross-module (separator-tolerant module
//      lookup — slash `std/field` and dot `std.field` both resolve);
//   2. the flow's own borrow params are SEEDED into its analysis context, so the
//      body can pass `f` to `std/field:clear`/`test`/`mark` (a user flow now
//      resolves the event it implements via either module spelling);
//   3. emit qualifies the bare foreign type from its phantom's module
//      (`*Field` -> `*koru_std.koru_field.Field`).
// Obligation params (`<!owned>`/`<owned!>`) are deliberately NOT seeded — the
// directionality rule still forbids an input parameter owning an obligation
// (see 330_076/079/080). Only borrows (no `!`) are seeded.
//
// Deterministic counter stands in for the wall clock (the real entry uses
// std/time:now) so the pass count is stable. 3 reuse passes, validates 78,498.
import std/io
import std/field
import std/control

pub tor tick { limit: i64, passes: i64 }
| live { limit: i64, passes: i64 }
| expired i64

pub tor run { limit: i64, f: *Field<std/field:field> } -> i64

tick = if(passes < limit)
| then => live { limit, passes }
| else => expired passes

run = #L tick(limit, passes: 0)
| live l |> std/field:clear(f) |> for(1..500)
    ! each i |> std/field:test(f, i): pv |> if(pv == 0)
        | then |> std/field:mark-multiples(f, from: 2 * i * (i + 1), stride: 2 * i + 1, limit: 499999)
    | done |> @L(l.limit, passes: l.passes + 1)
| expired e -> e

std/field:new(bits: 500000)
| field f |> run(limit: 3, f)
    | total n |> std/field:count-zeros(f, lo: 1, hi: 500000): c |> std/io:print.ln("passes: {{ n:d }}") |> std/io:print.ln("validated primes: {{ c + 1:d }}") |> std/field:free(f)
| err _ |> _
