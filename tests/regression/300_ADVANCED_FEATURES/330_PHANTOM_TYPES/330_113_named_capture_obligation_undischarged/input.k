// Pins: a BOUND head obligation stays enforced when the head acquires a
// CONTINUATION. The end of a top-level chain is a flow exit and must balance,
// exactly as a branch arm's hard terminal (`|> _`) does — 330_115 is the
// same obligation in the `| lit lamp` spelling, and the two must agree.
//
// The guarded shape is the pair: `light(): lamp` and
// `light(): lamp |> <anything>` are the same program with respect to `lamp`,
// so appending a continuation must not change whether the obligation is
// enforced. Adjacent shapes with their own pins: an unbound TERMINAL
// invocation returning an obligation (330_097), and a record-FIELD obligation
// at this position (330_096), which seeds per-field rather than riding the
// whole-value return_phantom.
//
// Auto-discharge is disabled so the wall is under test rather than the LIFO
// insertion — with the flag on, insertion emits the douse for this program and
// the question never reaches the checker. Per
// frag-obligation-enforcement-keys-off-return-binding, disable opts out of
// INSERTING, never out of the discard staying visible to enforcement.
import std/io
import app/lantern

app/lantern:light(): lamp |> std/io:print.ln("in the dark")
