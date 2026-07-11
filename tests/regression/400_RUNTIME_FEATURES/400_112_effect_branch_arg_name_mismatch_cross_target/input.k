// Cross-target dispatch under Koru's named-parameter rule. The effect handler
// `! tick i` sends its bound value to the `onTick` event, whose field is `slot`.
// Koru only supports NAMED parameters — a call's meaning must be derivable
// without context-hunting — so the dispatch is spelled `onTick(slot: i)`, never
// positionally. Both targets resolve the arg by name and print `hits=1`.
//
// HISTORY: this was a JS-target frontier pin (2026-06-01). It was written
// positionally as `onTick(i)`, which the Zig emitter bound BY INDEX while the JS
// `emitInlinePlainHandler` resolved BY FIELD-NAME only and aborted
// (UnsupportedConstruct) on the `i`/`slot` mismatch — a cross-target divergence.
// The punning wall (PARSE006) forecloses it at the frontend: a bare arg that
// doesn't pun to a parameter is rejected on EVERY target, so a positional
// mismatch can never reach an emitter. Labeled dispatch resolves by name
// identically on Zig and JS, so the old "make JS resolve positionally" fix is
// unnecessary — the rule closed the gap by construction. Green on both.
pub event ticker { n: u64 }
! tick u64
pub event onTick { slot: u64 }
pub event report {}

ticker(n: 1)
! tick i |> onTick(slot: i)
report()
