// PINS: the point-free thread lands in a `[with]`-scoped BARE name.
//
// `label` is written bare and resolves only through the `[with]` region.
// `tag` is written, so `word` is its one unfilled slot, and the thread —
// `origin`'s `-> string` — must fill it. `label` returns `word`, so the printed
// value IS the thread: if it never landed, `word` is unfilled and this cannot
// run at all.
//
// The two halves were each already green and the COMBINATION was not, because
// they ran in the wrong order. Stage-A canonicalize stamps `<main>:` onto every
// bare name; `resolve-with-scopes` re-qualifies the ones a `[with]` region owns;
// and the thread desugar looked declarations up BY PATH before that happened.
// It found nothing, silently did nothing, and the program failed passes later
// wearing another name — `_auto_8 obligation <empty!> was not discharged` in
// koru-libs' curl lift, which is where this was found.
//
// The fix runs the desugars again after `resolve-with-scopes`, in the elaborate
// segment. This pin is what stops that ordering from being undone: 641_011-014
// pin `[with]` resolution, 210_176 pins the thread, and neither notices if the
// two stop composing.
import std/io
import app/alpha

[with]app/alpha:origin() |> label(tag: "ok"): r |> std/io:print.ln("r={{ r:s }}")
