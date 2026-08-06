// PIN (RED): `<!state>` accepts a binding that never carried the obligation.
//
// `lend` returns `*H<issue>` — bare, no `!`, so nothing is minted. `drop` wants
// `*H<!issue>`, which means "consume the outstanding issue obligation". There
// is no outstanding obligation. The program frees something it does not own,
// and compiles clean.
//
// The direction that IS correct is the other one, and it is the whole point of
// the bare form: a value carrying `<issue!>` may be passed where `<issue>` is
// wanted, because a borrow does not consume. Verified: borrowing twice and then
// discharging is accepted, and the caller's obligation still auto-discharges.
// This pin is about the REVERSE being accepted too, which makes `<!state>` mean
// "state matches" rather than "a debt is settled".
//
// Why it matters beyond tidiness: it is the second half of 335_055. An aliased
// binding that owes nothing can still be used to free the object.
//
// EXPECT is provisional — no such diagnostic exists yet.
import app/h

app/h:lend(): z |> app/h:drop(h: z)
