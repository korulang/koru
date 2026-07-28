// PINS: an unbound `| full` payload threads THE VALUE THE STORE GAVE BACK, not
// an enclosing binding of the same type that was already consumed.
//
// This is 690_077 with one binding dropped. There, `| full f |> free(s: f.label)`
// names the give-back explicitly and is green. Here the arm is unbound, so the
// payload should thread by type (210_191/192) into `free`'s one unfilled
// parameter — and the value it must carry is the `label` the store just handed
// back, which is the only live `String<instance!>` at that point.
//
// MEASURED 2026-07-28 on THIS program — the payload does not reach `free` at
// all, so the value the store just handed back is left holding its obligation:
//
//     error[KORU030]: Resource 'label' carries obligation <instance!> was not
//                     discharged. Call one of: … std.string:free …
//
// The give-back reissues ownership on `| full` — that is the whole point of the
// branch, pinned green at 690_077 — and an unbound arm then drops it on the
// floor rather than threading it into the one call that would settle it.
//
// MECHANISM, measured by experiment 2026-07-28 (not inferred):
//
// The payload never threads at all. `ThreadHolder` does cover an arm payload
// (ast_transform.zig, `payload: *ast.Continuation`), but a `Thread` carries ONE
// base-type string, and a give-back payload is a named-field record
// (`{ label: *String<instance!> }`) with no single type. So it is not a
// candidate, and the slot is left to ordinary NAME PUNNING — which then fills
// from whatever enclosing binding happens to share the parameter's name.
//
// The symptom is therefore decided by a naming coincidence, which is how it was
// proved: rename the enclosing `take(s: c): p` to `: s`, matching `free`'s
// parameter `s`, and this exact program stops reporting "not discharged" and
// reports `Use-after-discharge: binding 's'` instead. That is the symptom
// koru-examples/downloads shows, where the arm is `| full |> curl:cancel()`,
// `cancel` takes `p:`, and the enclosing arm bound `p`.
//
// So punning is not misbehaving — it does what punning is specified to do. The
// gap is that the arm's OWN payload is not a candidate for the slot, so the
// innermost value loses to an outer one by default rather than by rule.
//
// NOT the same bug as 690_090, though the shape rhymes: that one is pass order
// inside store.kz's create Walk. Same "inner loses to outer" silhouette, two
// unrelated mechanisms — checked, because assuming they were one would have
// produced a single fix for two defects.
//
// DESIGN QUESTION FOR LARS, since a spelling is involved: 210_191 pins that an
// unbound payload threads BY TYPE, with an identity payload (one `__type_ref`
// field). Whether a ONE-FIELD RECORD payload threads that field is not covered
// by that pin or any other.
import std/io
import std/string
import std/store

std/store:new(todos, capacity: 2) {
    label: *std/string:String<std/string:instance!>,
    done: i64
}

std/string:from-page(text: "a")
| ok a |> std/string:take(s: a): m |> std/store:insert(todos) { label: m, done: 0 }
    | row _ |> std/string:from-page(text: "b")
        | ok b |> std/string:take(s: b): n |> std/store:insert(todos) { label: n, done: 0 }
            | row _ |> std/string:from-page(text: "c")
                | ok c |> std/string:take(s: c): p |> std/store:insert(todos) { label: p, done: 0 }
                    | row _ |> std/io:print.ln("ok")
                    | full |> std/string:free() |> std/io:print.ln("full")
                | err _ |> _
            | full _ |> std/io:print.ln("unexpected-full-2")
        | err _ |> _
    | full _ |> std/io:print.ln("unexpected-full-1")
| err _ |> _
