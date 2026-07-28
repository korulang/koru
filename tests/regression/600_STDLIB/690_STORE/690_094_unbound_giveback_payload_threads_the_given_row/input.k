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
// MECHANISM — measured by experiment, then read in the source. TWO passes are
// involved and they are not the same thing:
//
//   THE THREAD  binds by TYPE, and for a branch payload it reaches ONE STEP
//               only — "branch names are NOT durable symbols (a stage may repeat
//               `| ctx`), so they thread only one step" (ast_transform.zig:1080).
//               It declines here anyway: a `Thread` carries ONE base-type string
//               and a give-back payload is a named-field record with no single
//               type, so the payload is never a candidate for the slot.
//
//   THE PUN     binds by NAME, and reaches the FULL SUBTREE — "a `: bind` IS a
//               durable symbol, so its pun reaches its full subtree"
//               (ast_transform.zig:1081-1082). It synthesizes `field: field`
//               "as if the author had typed it" for any unfilled input whose
//               name matches a live bind.
//
// So the arm's own payload never competes, and the pun fills the empty slot from
// `take(s: c): p` — a bind several arms up the subtree, already consumed by the
// insert. The pun's own comment predicts this exactly: "the pun only inserts the
// reference; correctness is the checkers' job." The checker then does its job
// and reports the use-after-discharge.
//
// PROVED BY NAME, NOT BY TYPE, which is what separates the two passes: rename
// the enclosing bind to `: s`, matching `free`'s parameter, and this same
// program reports `Use-after-discharge: binding 's'` instead of the
// not-discharged error above. The TYPE was identical in both runs; only the NAME
// changed. koru-examples/downloads shows the first form because `cancel` takes
// `p:` and its enclosing arm bound `p`.
//
// NOT the same bug as 690_090, though the shape rhymes: that one is pass order
// inside store.kz's create Walk. Same "inner loses to outer" silhouette, two
// unrelated mechanisms — checked, because assuming they were one would have
// produced a single fix for two defects.
//
// FOR LARS, two design questions this exposes, neither a spelling to invent:
//   1. 210_191 pins that an unbound payload threads BY TYPE, with an IDENTITY
//      payload (one `__type_ref` field). Whether a ONE-FIELD RECORD payload
//      threads its field is unruled.
//   2. The pun's full-subtree reach is justified by uniqueness — "no shadowing
//      means the in-scope match is always unique". Uniqueness holds (KORU106
//      enforces it). But uniqueness is not LIVENESS: a consumed binding stays a
//      pun candidate arbitrarily deep in the subtree, and fills a slot the
//      author left empty on purpose.
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
