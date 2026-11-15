// PIN: a `for` in a tor chain is NOT terminal — the `| done` arm is the
// continuation, and the chain resumes after it.
//
// The `| done` sits at the branch column (one level under the `for`), the same
// column rule `if` follows for `| then` / `| else`. Writing a bare `|>` after
// the loop without `| done` is a *user* error, not a language wall: the loop
// has no continuation to return through.
//
// This shape is why the gallery's tick loops can use `for … | done |> …`
// instead of unrolling. It is also the simple case the known-failing
// 320_099 (sequential for-phases under a capture) is a harder variant of.
import std/io
import std/control

tor emit {}

emit = for(0..3)
    ! each i |> std/io:print.ln("each {{ i:d }}")
    | done |> std/io:print.ln("done")

emit()
