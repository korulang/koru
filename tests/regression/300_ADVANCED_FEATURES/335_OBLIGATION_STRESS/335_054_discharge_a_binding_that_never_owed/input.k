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
// EXPECT is provisional — no such diagnostic exists yet, and the spelling of
// the refusal is unruled.
//
// Related: 335_055 is this defect's consequence — an aliased binding that owes
// nothing is what makes the alias freeable.
import app/h

app/h:lend(): z |> app/h:drop(h: z)
