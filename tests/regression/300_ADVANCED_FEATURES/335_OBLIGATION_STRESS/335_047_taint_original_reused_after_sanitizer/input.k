// PIN (outside-in finding, human-authored): a `string<tainted!>` binding is
// discharged by a sanitizer accepting `<!tainted>`, the sanitizer's clean
// result is DROPPED, and the original tainted binding is then printed. This
// compiles, links, and prints the tainted payload.
//
// The obligation IS legitimately discharged here — `validate-response` consumed
// it, exactly as `free(f)` consumes `*File<opened!>`. What must be rejected is
// the LATER READ: after discharge, `response` is stale, and the only clean
// value that ever existed was the sanitizer's return, which went nowhere.
// This is the same stale-binding move as 335_024/335_025, so it must produce
// the same diagnostic.
//
// Observed (2026-07-30): accepted, `./a.out` prints "From network: Hello, World!".
// Use-after-discharge fires when the stale binding flows into another
// phantom-aware tor (two sanitizer calls in a row IS caught) but not when it
// flows into a plain-typed consumer like `std/io:print.ln`. That makes the
// check blind at precisely the sink taint tracking exists to guard.
//
// Suspected site: phantom_semantic_checker.zig validateArgument returns early on
// `expected_phantom == null` (:2828), 55 lines BEFORE the `context.isDisposed`
// check that raises the diagnostic (:2884). Disposal is a property of the
// binding, not of what the consumer wants — the gate is inverted.
//
// Sibling: 335_048 (same leak with the clean result correctly bound AND used,
// so the KORU100 unused-binding check does not incidentally cover it).
//
// Grounding:
//   - obligation on a primitive string:    330_068/input.k:14
//   - short tor body form (`name -> val`): 330_068/input.k:16
//   - sanitizer accepting <!label>:        330_068/input.k:18-20
//   - positive bind-then-use flow:         330_068/input.k:22
//   - Use-after-discharge diagnostic:      335_024/input.k:18, 335_025
//   - no-sanitizer-at-all negative twin:   330_069/input.k:18
//   - the taint label is an arbitrary phantom label; 330_068 spells it
//     `unsanitized`, this one spells it `tainted` (both are checked — the
//     undischarged form of this file does report `<tainted!>`).
import std/io

tor get-from-network {} -> string<tainted!>
get-from-network -> "Hello, World!"

tor validate-response { response: string<!tainted> } -> string
validate-response -> response

get-from-network(): response
|> validate-response(response)
|> std/io:print.ln("From network: {{response:s}}")
