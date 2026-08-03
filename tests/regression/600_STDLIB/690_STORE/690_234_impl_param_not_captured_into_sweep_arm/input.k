// PARAM CAPTURE LANDED (2026-08-03). This pin was red on purpose and carried
// its own flip instruction: "When param capture lands, this flips to MUST_RUN
// with expected '7 5'." Done — it is MUST_RUN now.
//
// What was missing was never a scope rule. A tor's parameter materializes as a
// `const d = __koru_event_input.d;` in the very frame that calls the sweep, one
// line above the call, exactly like the mid-chain bind that already worked. The
// capture collector simply never looked at the parameter list: it gathered
// mid-pipe binds, and gathered event INPUTS only when the host flow was a
// synthesized `__store_sweepbody_` (the nested-sweep case). A user tor never
// took that branch. The threading the fix needs was already there and already
// correct — a sweep arm inside a tor body captures a mid-chain bind today.
//
// The contrast this pin recorded is what proved it: a BRANCH binding threads
// fine, only the tor-parameter route was missing. Same body position, same
// generated arithmetic, same hop count — one origin, not one scope, was the
// whole difference.
//
// So the cost this pin named is paid off too: a "helper tor that writes a
// store" (kopium's absorb) no longer has to be inlined at its call sites.
//
// NOT governed by DESIGN.md T1. T1 is transplant-purity for a WATCH body —
// spliced into the store's write path, executing wherever a write happens, so
// it genuinely cannot close over its declaring scope. A sweep body runs AT the
// sweep site in the caller's own frame; its lift into a handler fn is codegen,
// not relocation to a foreign execution context.
//
// STILL OPEN, and a different defect: capturing anything into a sweep body
// declared inside an imported MODULE fails with `use of undeclared identifier
// '__koru_store_bodies'`. That predates this change — a mid-chain bind capture
// in a module sweep body fails identically — and is the store symbol being
// named from a namespace it is not in.
import std/io
import std/store

std/store:new(box, capacity: 4) { n: i64 }

std/store:insert(box) { n: 7 }
| row _ |> _
| full |> _

tor shout { d: i64 }
shout = std/store:query(box)
! query r |> std/io:print.ln("{{ r.n:d }} {{ d:d }}")

shout(d: 5)
