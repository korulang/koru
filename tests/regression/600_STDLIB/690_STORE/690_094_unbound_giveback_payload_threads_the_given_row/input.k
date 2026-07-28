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
// A SECOND SYMPTOM, same gap, different program: in koru-examples/downloads the
// batch's `| full` arm is `| full |> koru/curl:cancel()`, and there the thread
// does not come up empty — it reaches PAST the reissued value to the enclosing
// `| started p`, already consumed by the insert, and reports
// `KORU030: Use-after-discharge: binding 'p' was already discharged`. Empty here,
// wrong-target there; both are the unbound give-back failing to thread.
//
// Whichever way it fails, the rule is resolution order, innermost first: an
// arm's own payload is the innermost thing in scope in its body. Compare
// 690_090, measured the same day, where a sweep arm's row binding loses to a
// store name — something resolves outward when it should resolve inward.
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
