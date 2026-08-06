// PIN (RED): `<!state>` accepts a binding that never carried the obligation.
//
// `lend` returns `*H<issue>` — bare, no `!`, so nothing is minted. `drop` wants
// `*H<!issue>`, which reads as "consume the outstanding issue obligation".
// There is no outstanding obligation. The program frees something it does not
// own, and compiles clean.
//
// NOTHING HERE DEPENDS ON A PROC BODY. Both declarations are honest and an
// honest implementation of each is the obvious one. This is a question about
// what `<!state>` means at the type level: "a debt is settled", or merely
// "the state matches". Today it is the second, and the second cannot be a
// safety property — a value can be in a state without owing anything.
//
// The direction that IS correct, and is the whole point of the bare form: a
// value carrying `<issue!>` may be passed where `<issue>` is wanted, because a
// borrow does not consume. Verified — borrowing twice and then discharging is
// accepted, and the caller's obligation still auto-discharges afterwards. This
// pin is only about the REVERSE also being accepted.
//
// ⚖️ WHERE THE BOUNDARY IS, because it was probed and got this wrong once.
// A `|zig` proc is the unsafe escape hatch; a body that contradicts its own
// declaration is out of scope, and catching it would mean analysing the Zig.
// A first draft of this cluster pinned exactly that — `relend { h: *H<issue> }
// -> *H<issue!>` whose body returned the borrowed pointer instead of minting a
// new resource — and called the resulting double free a hole in the language.
// It is not. The declaration is legitimate (an honest `relend` allocates), the
// BODY lied, and Lars ruled that class out on 2026-07-24. That pin was
// withdrawn. What remains here needs no body at all.
//
// ⛔ RULED BY LARS 2026-08-06: "it shouldn't allow DISCHARGING a handle without
// an obligation. That should be stopped in its tracks in the obligation
// checker." So the refusal is WANTED. It is not built, and the attempt is
// recorded here because it failed for a reason worth knowing.
//
// THE OBVIOUS FIX DOES NOT WORK YET, AND 330_076 IS WHY.
// The consume site (`phantom_semantic_checker`, where a `<!state>` parameter
// clears the obligation and poisons the binding) never asks whether a debt
// exists. Adding that question is four lines. Both predicates were tried:
//
//   (a) "is the binding in cleanup_obligations?"  — false-fires
//   (b) "does the binding's own recorded state carry `!`?" — false-fires
//
// Both refuse this, which is legitimate and common:
//
//   ~tor pass-through { h: *Handle<!owned> }
//   ~pass-through = sink(h)          # delegate the transferred obligation
//
// A `<!state>` PARAMETER means the caller handed the debt in, so the body may
// settle it once. The seeding for that is written (the impl-param block builds
// `owned!` and calls setWithType, which does register the cleanup obligation) —
// but by the time the consume site reads it, `h` carries `input:owned`, bare.
// The `!` is not arriving.
//
// That is 330_076's subject verbatim — "an owned obligation CAN enter a pure
// impl through a CONSUMING parameter" — and 330_076 is RED today, on main and
// everywhere else. So this wall is BLOCKED ON 330_076, not on the predicate or
// on a ruling. Fix the seeding first; then either predicate above closes this
// pin, and 335_055 with it.
//
// EXPECT is provisional — the wanted diagnostic does not exist yet.
//
// Related: 335_055 is this defect's consequence — an aliased binding that owes
// nothing is what makes the alias freeable.
import app/h

app/h:lend(): z |> app/h:drop(h: z)
