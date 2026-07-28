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
// MECHANISM, after the 2026-07-28 ruling that argument resolution selects by
// TYPE and never by name (210_194, 210_156):
//
// The arm's payload never competes, and there are TWO independent reasons —
// the second one measured 2026-07-28 and load-bearing:
//
//   (a) a `Thread` carries ONE base-type string, and this store has TWO owned
//       columns, so armPayloadType declines a multi-field payload outright.
//   (b) more fundamentally, THE BRANCH DOES NOT EXIST YET. Threading is a
//       Stage-A desugar ("after the point-free rewrite, before every checker");
//       std/store synthesizes `| full` in the BACKEND. So no store-synthesized
//       arm can ever offer a payload to the thread, whatever its arity — a
//       one-column store with an identity payload cannot either, which is why
//       koru-examples/downloads still writes `| full f |> cancel(p: f)` after
//       the identity-payload change landed.
//
// (b) means this pin is not fixed by making payloads threadable. It needs the
// arm to exist when threading runs, which is a pass-ordering question.
//
// What the ruling DID change is which wrong thing fills the slot instead. The
// nearest in-scope binding of matching type is `take(s: c): p`, a `*String`
// several arms up and already consumed by the insert, so the fill lands there
// and the obligation checker says so:
//
//     error[KORU030]: Use-after-discharge: binding 'p' was already discharged
//
// Before the ruling this same program said "Resource 'label' ... was not
// discharged", because the selector was the NAME and `p` did not match `s`. The
// bug did not move; the selector did. It now fires predictably instead of on a
// naming coincidence, and it names the spent binding rather than reporting a
// vague unsettled obligation — which is the intended consequence of letting the
// checker own liveness rather than teaching the fill about it.
//
// NOT the same bug as 690_090, though the shape rhymes: that one is pass order
// inside store.kz's create Walk.
//
// THE DESIGN QUESTION THIS PIN CARRIES, and the only thing between it and green:
// 210_191 pins that an unbound payload threads BY TYPE with an IDENTITY payload
// (one `__type_ref` field). Whether a ONE-FIELD RECORD payload offers its field
// as a candidate is unruled. If it does, the payload is nearer than any
// enclosing bind and wins on the same nearest-first rule, and this goes green
// with nothing else changing.
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
