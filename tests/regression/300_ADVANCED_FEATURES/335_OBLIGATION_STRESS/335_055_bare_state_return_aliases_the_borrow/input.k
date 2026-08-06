// PIN (RED): a tor returns the subject it BORROWED, and the alias is untracked.
//
// `touch` borrows `<issue>` and returns `<issue>`. `y` and `x` are the same
// pointer under two names. Discharging one does not poison the other, so the
// object is freed twice — through a binding that never owed (335_054) and
// through the one that did.
//
// THE BODY DOES NOT LIE, and that is why this pin stands where a first draft of
// its sibling did not. `-> *H<issue>` promises a `*H` in state `issue` owing
// nothing; returning the borrowed pointer satisfies that reading exactly. The
// ambiguity is in the DECLARATION FORM, not the implementation — which is what
// makes it the language's problem. Refuse `drop` on a binding that owes nothing
// (335_054) and this program frees once instead of twice, with no analysis of
// any Zig.
//
// This is the realistic shape rather than a contrived one: it is the fluent
// builder, and `koru_std/json.kz` uses it today at `object.set` and
// `array.push`. Those are the only two bare-state returns in the whole of
// koru_std + koru-libs — counted 2026-08-06 — so the wall implied by this pin
// costs exactly two migrations.
//
// The correct spelling for a mutating builder step is a VOID borrow: take the
// subject, mutate it, return NOTHING, and let the caller keep naming its own
// binding. Verified to work and to keep the wall — a chain of void borrows
// compiles and runs, and a borrow AFTER the discharge is already refused with
// "Use-after-discharge". Consume-and-re-issue (`tx.exec`) is the OTHER correct
// form and belongs where the state genuinely transitions; a builder step that
// is `building` before and `building` after transitions nothing, so threading
// it would model a change that is not happening.
//
// ADJACENT AND DELIBERATELY NOT PINNED: the SPATIAL version of the same
// aliasing — one binding passed as two parameters of one call,
// `merge(dst: o, src: o)`. The language cannot say two borrows must differ, and
// it accepts that program. It is left unpinned because harm was NOT
// demonstrated: a self-append over 200,000 bytes, forcing reallocation, ran
// clean (len=400000, exit 0). The checking gap is certain, the consequence is
// not, and a MUST_ERROR asserting a refusal nobody has justified would pin a
// design opinion rather than a defect. Exclusivity is a separate question from
// this pin, which is about ALIASED RETURNS.
//
// EXPECT is provisional — no such diagnostic exists yet.
import app/h

app/h:make(): x |> app/h:touch(h: x): y |> app/h:drop(h: x) |> app/h:drop(h: y)
