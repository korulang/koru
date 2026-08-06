// PIN (RED — a well-typed program that DOUBLE FREES).
//
// `relend` takes `h` as a BARE `<issue>` — a borrow for the duration of the
// call, which does not consume the caller's obligation — and returns the very
// same pointer carrying `<issue!>`, a NEW obligation. One object now owes twice.
// Both debts are then paid. Measured: exit 134 (abort, double free).
//
// The language has no notion that two bindings can name one value, so
// discharging `x` does not poison `y`. Threading is NOT the missing piece and
// this is not a string problem: `relend` is six lines of ordinary Koru.
//
// ⚠️ THIS FALSIFIES A CLAIM THE COMPILER MAKES ABOUT ITSELF.
// src/emitter_helpers.zig, justifying the move off DebugAllocator:
//   "What this trades away: DebugAllocator's double-free/invalid-free detection
//    at the allocator layer — Koru's primary defense there is already the
//    phantom obligation system (double-free is a COMPILE-TIME error for
//    well-typed programs), so this is a backstop loss, not a loss of the
//    language's actual safety guarantee."
// Before this pin the corpus contained ZERO double-free tests, so the guarantee
// that justified dropping the allocator's detection was never checked.
//
// EXPECT is provisional. The refusal does not exist yet and its spelling is
// unruled; `CONTAINS obligation` is a placeholder that must be tightened to the
// real diagnostic when one lands.
//
// Related: 335_054 (discharging a binding that never owed) and 335_055 (the
// same alias returned WITHOUT a new obligation). 610_007 is the third face,
// where the alias is a plain `string` carrying no phantom at all.
import app/h

app/h:make(): x |> app/h:relend(h: x): y |> app/h:drop(h: x) |> app/h:drop(h: y)
