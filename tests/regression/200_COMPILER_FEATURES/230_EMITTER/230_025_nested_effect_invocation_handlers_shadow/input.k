// PINS: a nested effectful invocation inside an effect arm body gets its
// own `Handlers_N` — the counter that names synthesized handler structs is
// unique across emission contexts, so a `query()` inside `! tick` emits
// `Handlers_1` beside the enclosing chain's `Handlers_0` and the emitted
// file compiles.
//
// This was pinned as MUST_ERROR against the 'local constant shadows' death
// (result_counter restarted per emission context while the Zig block scope
// was shared); 660b2b4ba made the numbering unique and the pin is now the
// positive form: it compiles AND runs — `w 42 d 1 n 5`.
//
// Surfaced by koru-libs/clay/tests/gallery_comp.k: a `clay:each` inside
// `! frame` collided with `frames`' own Handlers as two module-level
// `__HandlersCaps_16` structs. This is the same numbering bug at block
// scope: nested effectful call inside `! tick` when-guard.
import std/io
import std/store

std/store:new(rows, capacity: 8) { n: 0[i64] }
std/store:insert(rows) { n: 5 }

pub tor query { q: i64 }
! ask i64 -> i64
| done i64

query = ask(q): a => done a

pub tor ticker { n: usize }
! tick usize

proc ticker|zig {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        tick(i);
    }
}

query(q: 41)
! ask v -> v + 1
| done w |> ticker(n: 3)
    ! tick i when i == 0
        |> query(q: @as(i64, @intCast(i)))
            ! ask v -> v + 1
            | done d |> std/store:query(rows)
                ! query r |> std/io:print.ln("w {{ w:d }} d {{ d:d }} n {{ r.n:d }}")
