---
type: belief
id: frag-the-host-compilers-diagnostics-hid-the-absence-of-ours
provenance: probing what `f(n)` should do when `n` is also a declared field; the answer required knowing what an omitted required argument does today, and it does nothing
ts: 2026-08-02
---

# Zig's diagnostics hid the fact that Koru had none (belief)

Koru has no call-site arity check. Ten months, 1454 tests, and a required tor
input can simply be omitted. Measured, all four cells:

| call site | impl | today |
| --- | --- | --- |
| required param omitted, impl never reads it | subflow | **compiles, runs, silent** |
| required param omitted, impl reads it | subflow | raw Zig `use of undeclared identifier 'b'` |
| required param omitted | `\|zig` proc | raw Zig `missing struct field: b` |
| required `Expression` param omitted | either | **compiles, silent** |

`KORU080 // Missing required field` has been in the registry the whole time. Its
only emission site in the tree is `koru_std/testing.kz`, for mock branches.

## Why nobody noticed, which is the actual belief

**Because Zig caught the cases that hurt, and a borrowed diagnostic is
indistinguishable from an owned one until you look at where it came from.** A
missing argument the impl *uses* becomes an undeclared identifier in generated
Zig; a missing struct field on the proc path becomes a Zig struct error. Both are
loud. Both stop the build. Neither is Koru's, and neither covers the case where
the parameter is declared and never read — which is exactly the case a human
would call a bug and a compiler should call an error.

So the surface tested as "mostly working" for ten months, and its gap is shaped
like the host's blind spot rather than like anything in Koru's own design.

**The generalisation: for any rule you believe you enforce, find YOUR emission
site.** Not the failing test — the failing test may be failing for the host's
reasons. A rule with a registry entry, a name, and no emission site is a rule
you are borrowing.

## It was not an oversight — it was written down as ACCEPTABLE

The strongest evidence turned up last, when the new wall turned a green test
red. `510_063_missing_event_param`, in the negative-test cluster, pinned exactly
this program and carried this header:

> `// ACCEPTABLE: Backend Zig error "missing struct field: y"`
> `// (We don't re-implement Zig's type system)`

So someone saw the gap, reasoned about it, decided, and recorded the decision as
a passing test. For ten months the corpus asserted that Koru *should* borrow
this diagnostic.

The reasoning is the interesting part, because it is nearly right. Re-deriving
Zig's type system would be foolish. **But arity is not the host's type system —
it is Koru's own calling convention**, and the two are easy to conflate at the
moment the host happens to catch your case. Delegating it meant inheriting the
host's blind spot along with its coverage, and the blind spot is not a corner:
it is every parameter the impl declares and does not read.

A pinned "acceptable" is a much stronger form of this belief than a missing
check. A missing check is an absence and absences get found. **A documented
decision to borrow is load-bearing: it answers the question in advance, so
nobody asks it again.**

## The libraries had already built it, privately, five times

The corroborating evidence was in plain sight and read as diligence: `std/parser:parse`
hand-rolls *"needs its grammar named"*, `std/store:insert` hand-rolls *"requires a
store name and a row block"*, `std/kernel:init` falls back to a hardcoded shape.
Every library author who cared built this wall privately, one message at a time.
**A rule re-implemented independently by several libraries is a rule the language
does not have** — the duplication is the symptom, and it looks like good error
messages right up until you count the ones that are missing.

## Defaults were never implemented; they LEAK

`b: i32 = 5` parses, and on the proc path it works. It is not a feature.
`Field.type` is literally the string `"i32 = 5"` — the default is the tail of the
type, never split off, pasted verbatim into the generated Zig `Input` struct
where **Zig** applies it. A bare-return subflow has no Input struct, binds args
straight from the call site, never touches the type string, and the default
evaporates.

`auto_discharge_inserter.zig` carries the honest note beside its auto-fill
classifier — `TODO: event-input defaults when the surface supports them on
shapes`. Someone knew. What nobody knew is that the syntax was already *accepted*
and already *half-working*, so the TODO reads as "not built yet" when the truth
is "unbuilt, reachable, and silently type-corrupting": every consumer of
`field.type` sees `"i32 = 5"` where it expects a type.

**An unparsed surface that reaches the host verbatim is worse than an
unimplemented one**, because it works often enough to be used and it poisons a
field that other passes read.

## Open

- Whether `?T` and `= default` should coexist on one field, and what
  `b: ?i32 = 5` would mean. Both are currently type-string tails, so today it
  "works" by accident in exactly one direction.
- What KORU080 must exempt. A comptime transform's shape declares parameters the
  compiler injects — `invocation`, `item`, `program`, `allocator`, `reporter`,
  `source` — and the author writes none of them. Getting that list wrong turns
  the wall into a flood across the whole stdlib, so the exemption is the risky
  half of the fix, not the check.

Related: [[frag-a-fix-installed-at-the-site-that-needed-it]] — same week, same
shape one turn over: there the property existed and was installed too narrowly;
here the property was never installed and the host covered for it.

## The host also hides a DEFECT, not only a missing check

Every case above is a rule Koru does not enforce and Zig does. There is a
second shape that reads identically from the author's chair: a rule Koru does
own, implemented wrongly, whose failure is reported in the host's vocabulary at
a host location.

`std/io:print.ln` lowers its message to a Zig format string, and passed the
author's own braces through unescaped. The build failed inside the host's
`std/fmt.zig` at comptime — in the *standard library's* source, several frames
below any file the Koru author wrote. The defect is entirely Koru's; the
diagnostic is entirely Zig's.

What makes this belong here rather than in a file of its own is that the tell
is unchanged and is still the only one that works: **look at where the
diagnostic came from.** A Koru surface whose misuse is reported at a host
location has either delegated a rule or broken one, and the author cannot tell
those apart — both arrive as an error they cannot act on, about code they did
not write.

The new part is a defect class rather than an enforcement gap:

- **A surface that lowers to a host construct owes the host's metacharacters an
  escape.** Whatever the surface accepts as *data* it must be able to carry, or
  the host's syntax is leaking into the surface's value space. Format strings
  are the first instance found, not the only one available — every place Koru
  splices user text into generated host source is the same question, and each
  one answers it separately today.

## The borrowed coverage can be a SKIP, not a diagnostic (2026-10-03)

Two more instances of the same shape surfaced in one sweep, and neither
arrived as a missing *check* — both arrived as a wall that existed in one
place and was silently borrowed everywhere else.

`=>` inside a `! query` sweep arm died in emitted Zig
(`type 'void' does not support struct initialization syntax` inside a
synthesized unit the author never wrote) — kopium wired/holes/10. The
glyph wall existed and worked: `shape_checker` walls `=>` on a void effect
correctly, pinned by 400_199. But the query transform grafts the user's
arm body into a synthesized void callback and marks the graft
`is_transformed_subtree` — a flag that means "transform-owned data, already
validated" — and every checker walk skips marked subtrees. **The skip is
correct for what the transform wrote and wrong for what the transform
grafted**: the user's text crossed the checker boundary carrying a flag
that was never meant for it. The wall has to run pre-graft, in the
transform, while the user body is still legible — post-graft it is
invisible to every checker by design. `refuseUncrossable` — in
`src/ast.zig`, since the boundary is a cross-cutting transform contract —
is that wall; store wraps it in `refuseVoidArm` (in
`store.uncrossable.kz`, beside the `Graft` it guards) for the one
exemption: `new`'s `step`/`wait` arms, whose `=>` legitimately constructs
declared pump verdicts. 690_357–360 pin it across store's four graft
families; sweeping the rest of `koru_std` for the same void-graft shape
found two more — 697_016 (`grid:sweep`) and 699_035 (channel consumer
arms), both dying the identical raw-Zig death until walled. The census
is now closed: every other surface either carries the tor context
through the clone (`impl_of` on rings/taps/`pump.run` — `=>` there is
legal), walls the construct itself before the body is consumed
(parser's KORU163 picker shape, supervisor's arm vocabulary plus
KORU105 on nested arms), or can't reach the position (pump verb units
carry a verdict contract, and `=>` parses as a stray step there).

The second instance ran the same shape the other direction. The JS emitter
never carried a `[norun]` guard — `std/indexes:store`'s site-claiming flow
reached `flowN()` and leaked the parser's `source: <implicit_source>`
marker verbatim into emitted JS, a syntax error at `node`. It had never
needed the guard: the comptime classifier stripped every Source-fielded
event's flows wholesale, so `[norun]` sites never survived to JS emission.
When the classifier was corrected to key on `Program` only — itself the
right fix — the borrowed coverage vanished and the absent guard stood
naked, four index tests red at `js-runtime`. The Zig walk had carried the
explicit check the whole time.

The generalisation, sharper now: **coverage borrowed from a pass whose job
is something else is a wall you do not have.** The classifier's job was
timing, not norun; the subtree marker's job was transform bookkeeping, not
user-code exoneration. Both covered the gap for free and silently, which is
why the gaps were invisible until the borrowed half was touched. The tell
stays the same — look at where the refusal comes from — but add a second
question: *what else was standing between this construct and the host?* If
the answer is a flag or a filter that exists for a different reason, the
wall is borrowed.

## A contract collision needs no borrowed flag — it needs no pass at all
(2026-10-03)

Same family, one step upstream: not a body grafted past a skip-list, but
two declaration halves each legal alone that combine into a program no
backend can represent. A tor declared `-> T` AND `| named` outcomes kept
both in the `EventDecl` — `return_type` wins at codegen, so every named
branch is unreachable ("a bare return has no tags", KORU021, reported at
the *call site* for vocabulary declared at the *definition*), and a `| ?!`
panic arm was worse: it joins the outcome union while the bare return emits
an empty switch tag — raw-Zig death again. No checker skipped anything;
there was simply no site that ever held both halves and asked whether they
could coexist. `PARSE003` now refuses at the declaration, where the author
can act on it (210_309/210_310). Effect arms stay legal — `!` yields are
not outcomes (210_189 and the pump `! ?polled` decls pin the legal mix).
The census question generalises once more: **any two spellings the parser
accepts independently owe a reconciliation site for the combination** — if
none exists, the pair's verdict is whatever the host happens to say.

## A feature can be honored end-to-end and still borrow its gate (2026-10-10)

The strongest camouflage the family has produced is not a missing check but
a *working* feature. `r[mutable]` parsed, sat on the binding, and was read
at emission — `var r` instead of `const r`, the only thing the annotation
exists to do. `ptr: &r` on an unannotated `r` passed all twenty pipeline
passes; the refusal lived solely in Zig's `*const i32` → `*i32`
const-discard, reported on emitted coordinates. Because the feature visibly
worked, nobody asked whether it was guarded — honored surface hides a
borrowed wall better than absent surface ever could.

KORU107 now refuses in the frontend, naming the binding, the mutable
parameter it fed, and the annotation to add (510_126; the annotated
`ptr: &r` in 020_007 stays the control). The `&name` census is closed: the
only green use was annotated; every other `&` in the suite is a host `var`
or Zig-body code. Two edges stay delegated by choice: `&param` (tor
parameters are not in the binding scope the walk builds) and `-> &binding`
produce sites (no consumer to compare against at that site).

The rule sharpens again: **the audit is not "does the feature behave" but
"does its misuse refuse in our vocabulary."** Behavior can be completely
correct while the gate is borrowed — correctness is exactly what hides it.

## A borrowed refusal can be recorded AS borrowed (2026-10-18)

The family's usual shape is a borrowed diagnostic nobody noticed. KORU108
(400_213/400_214, refusing flow-bound names read off their path) is the
opposite: a check written knowing its own edge. Its refusal is scoped to
names bound *somewhere* in the flow — a name bound nowhere, or a reference
inside library text the core may not open (`{{ }}` interpolation, `stored
{}` bodies), still reaches the host's `use of undeclared identifier`.

What keeps this from being the old failure is that the delegation is now
*pinned as delegation*. The harness's bare `BACKEND_COMPILE_ERROR` marker
passes only while `backend.err` carries no `error[KORU…]` — so a test
marked `BACKEND_COMPILE_ERROR` is a tripwire: the day koruc refuses the
name itself, the marker falls through to `no-error-pin` and the test goes
red until the new diagnostic is pinned. Three pins hold the boundary:
`220_046` (name bound nowhere → host), `400_212` (bound name at the join
inside `{{ }}` → host), `690_367` (bound name inside a store write body →
host). "A documented decision to borrow is load-bearing" — now the suite
itself carries the documentation, and it self-invalidates when the
borrowing ends.

## The coverage wall surfaced another borrow (2026-10-21)

The variant-coverage wall flagged `__BlkResult` / `__LnResult` — tagged
unions `fmt.blk`/`ln` emitted for unbound call sites, whose only consumer
(the `| formatted` / `| line` branch spelling) had already been removed
from the grammar. The first execution the arm ever got produced a raw Zig
`expected '[]const u8', found '__BlkResult'` — the borrowed diagnostic
again, this time *inside dead surface*. The unbound arm now refuses with
`KORU180` at the transform (620_020/620_021 pin both), and the unions are
deleted — the exemptions came off the allow file, not onto it permanently.

The fix exposed a second, quieter instance of the same family: declaring
the injected `reporter` param flipped the tor out of `all_machinery`, and
PARSE006 started refusing every bare `std/fmt:ln("...")` call — because
`isTransformMachineryType`'s substring scan didn't know `ErrorReporter`.
44 stdlib files already declared the param; no all-machinery tor had ever
carried it, so the hole was invisible until a tor tried. The exemption
predicate described an older version of the injection contract — a
*checker* borrow, not a diagnostic one: the rule "what counts as injected
machinery" lived in one place, the contract in another.

## A spelled operator borrows an operand contract that was never declared (2026-11-03)

Every cell above has a rule-shaped hole: a check skipped, a graft that
crossed a boundary, a feature whose gate lived elsewhere. The binary
operators add a cell where there was never a rule to begin with. `a < b`
on `[]u8` operands — and on string literals — clears the frontend, clears
shape check, and reaches emitted Zig, where `operator < not allowed for
type '[]u8'` is the first verdict anything renders. Koru owns scalar
comparisons and has no ordering vocabulary for slices — no compare event,
no `<` lowering — so the only diagnostic the construct can produce is the
host's. The distinction that makes it worth a cell of its own: this is not
a wall Koru built somewhere and failed to place on this path, and not a
delegation somebody pinned as acceptable — the operand contract of the
binary operators is *undeclared*, so each combination's verdict is
whatever the host happens to say about it. It surfaced the same way the
rest of the family does — a green `-c` and a raw Zig death — while
spelling top-N word frequency (820_007), where alphabetical tie-break
wants exactly this primitive. The audit question stretches one more
notch: not only "where does the refusal come from" but *"was the operand
space ever declared anywhere"* — an operator whose contract is nowhere is
a rule every call site borrows from the host.
