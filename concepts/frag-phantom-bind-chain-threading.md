---
type: belief
id: frag-phantom-bind-chain-threading
provenance: introduced with the phantom bind-chain threading fix — Lars-ruled 2026-07-12 ("exactly the same for these flat phantom binds as with sub flows")
ts: 2026-07-12
---

# Phantom obligations thread across CHAINED flat bind-form consumers (belief)

Migrating a lone continuation branch on a phantom-returning event
(`| tx t |> …`) to the single-return bind form (`tx.begin(conn: c): t |> …`)
must carry the re-issued `<state!>` obligation across EVERY link of the
chain — identically to a single bind and to a loop back-edge. Lars ruled it
2026-07-12: "it needs to be exactly the same for these flat phantom binds as
with sub flows." This is the phantom-checker corollary of
[[frag-single-return-form-is-universal]]: if the bare-return form is
universal, its obligation must thread everywhere the branch-payload
obligation used to.

The discriminator was never "subflow vs flat" — that was a misread of the
green corpus. The green phantom tests (330_074/082/085) happen to thread
through a loop back-edge OR a single top-level bind
(`spin(): hf |> dispose(h: hf)`), and both work. The untested/broken shape
was specifically a **chained** flat bind: `make(): h |> t1(h): a |> fin(h: a)`
lost the obligation from the first chained link onward. A single flat bind
already worked.

Root cause (phantom_semantic_checker.zig): only the flow HEAD registered its
bare-return bind (`recordBareReturnBind` at the flow head, ~line 1056), and a
named branch's nested continuations registered theirs. The two bare-return
HEAD-chain paths (the 0-branch void head and the empty-branch void chain)
resolved nested continuations against the step's event but never recorded the
step invocation's own `return_binding` phantom — so an intermediate step's
bind (`t1(h): a`) reached its consumer with no tracked obligation (spurious
KORU030 on `a`, cascading to every downstream link). Fix: `recordBareReturnBind`
factored out and called in both head-chain paths before recursing.

Pinned: 330_093 (flat 3-link phantom chain, MUST_RUN). Unblocks the 2104
transaction cluster and the wider KORU030 burn-down class, whose consumers
convert branch-form → bind-form once the compiler threads the obligation.
Relates to [[frag-comptime-obligation-discipline]] and the escape-driven
stack-allocation reasoning (obligation = lifetime proof).

## Discard is mechanical too: `: _` == `| _ |>`

Lars sharpened the rule 2026-07-12: the migration is *completely mechanical* —
"different syntax and different code generation for the exact same concept."
So a DISCARDED obligation-carrying return behaves identically in both
spellings. The old `| committed _ |> _` branch discard auto-discharged the
dropped payload; therefore `tx.commit(...): _` must auto-discharge the dropped
`<active!>` connection the same way. There is no design fork — a `: _` that
leaks or errors is a codegen bug, not a question.

Root cause + fix (auto_discharge_inserter.zig): the inserter already
synthesized a real name for a `cont.binding == "_"` branch discard (so the
inserted discharge has something to reference), but only checked
`cont.binding` — the bare-return discard lives in the node's
`return_binding`, so `: _` was left as a literal `_`, and the synthesized
`close(conn: _)` leaked an unusable `_` into Zig.
`cloneContinuationWithReturnBinding` + a trigger mirroring the branch case
(fires only when the return carries an obligation; a plain `: _` stays a
genuine discard) materialize `_` → `_auto_N`. Pinned 330_094 (nested discard,
green).

Flow-head continuation-less discharge (CLOSED, 330_095 green): a flow-head
obligation with nothing after it (`~make(): _` / `~make(): h`) is a flow exit
and auto-discharges at the head, exactly like the nested case — Lars ruled the
migration completely mechanical, so a continuation-less head must not leak
(silently for `: _`, as a Zig unused-const for a named bind). The head has no
terminal for the terminator-disposal machinery to fire on, so the inserter
synthesizes one (`giveContinuationlessHeadTerminal`: rename a `_` head bind to
a synthetic, append an explicit `|> _`) and re-runs — the obligation then
discharges through the one existing disposal path, no bespoke head-disposal.
Fired only when `context.hasObligations()` (a real cleanup obligation), so a
non-issuing phantom return discarded at the head is untouched.

Flow-head discharge WITH continuations (CLOSED, 330_021/023/046 green): the
continuation-less path above only fired when the head IS the flow exit. But a
`_` head that carries an obligation AND has a chain after it
(`open(): _ |> open(): f2 |> …`, an `if`, a `for`) seeds its obligation under
the literal name `_` (the head-bind seeding block) and never renamed it — the
downstream terminator-disposal then referenced `_` (`.file = _`, unusable in
Zig). `renameHeadDiscardBinding` is the has-continuations twin: rename the `_`
head bind to a synthetic but — unlike the continuation-less twin — do NOT
append a `|> _`, because the existing continuations already provide the flow
exit where disposal fires. Fires when the head event returns a phantom
obligation.

## The recurring shape: branch-only logic must learn the bare return

Every fix in this concept is the same shape — a piece of the phantom machinery
knew the single-continuation-branch form but not its bare-return twin, because
the migration is mechanical and the code predates it. Threading
(validateContinuation head/nested), discard rename (cont.binding vs
return_binding), flow-head discharge (terminal vs continuation-less head), and
now discharge-suggestion re-issuer detection: `eventReIssuesObligation` only
scanned `event_decl.branches`, so a transition like `tx.exec` (consumes
`<!active>`, re-issues `<active!>` via `-> *Transaction<active!>`) was wrongly
offered as a discharge option ("Call one of: tx.exec, …", 2104_22 pins the
NOT_CONTAINS). Extended to the bare-return form. When touching any phantom pass,
assume it may still be branch-only and check the `-> T<phantom>` path too.

## The deeper invariant: `_` discards the NAME, never the VALUE

The unifying belief under every instance above: a `_` binding says "I will not
*name* this," NOT "this value is unreferenced." Whenever the compiler still has
to reach the value — auto-discharge must dispose an obligation, a capture cell
is read and written by the accumulation machinery — the `_` must be renamed to
a real synthetic identifier before emission. A bare `_` is not a declarable or
readable Zig identifier, so leaking one is always a codegen bug, never a design
question. This is why the rename machinery recurs in so many places.

It reaches BEYOND the phantom passes: `capture {..} ! as _` (320_126) used `_`
as the accumulator cell name in `control.kz` lowering, emitting an
undeclarable `var _: __KoruCaptureT__`. `cell_name` is the single source for
the cell's var decl, type name, write target, and after-read, so synthesizing
`__koru_cap_{line}` when it is `_` covers them all at once — the same
"referenced ⇒ needs a real name" move, in a non-phantom site. The invariant is
about `_` semantics generally, not any one pass.

## The uniformity ruling had a live counterexample: `std/store:query` — FIXED

2026-08-04. Lars's ruling above is about SAMENESS — an obligation must thread
everywhere, and a new binding form is not permission to thread differently. A
borrow into a sweep arm turns out to break it, and only in one construct.

Same `<list>` borrow, same push, three sweeps:

- `for(0..N) ! each` — threads. Compiles.
- `std/fs:read-lines ! line` — threads. `810_242_day24_part2` has pushed regex
  captures into a list from inside the line arm for weeks, green.
- `std/store:query ! query` — **does not thread.** KORU030.

`690_252` pins it. The store's sweep is the language's flagship data operation
and the one place a user most wants a resource in hand, so this is the worst
possible construct to be the exception.

**The mechanism is an emission difference, not a semantic one**, which is what
makes it a defect rather than a rule. A `for` body is emitted as an inline
block that references the outer binding directly. A store sweep body is lifted
into a detached event handler invoked per row, so an outer binding can only
arrive as a declared input — and a phantom-typed one has nowhere to be
declared. Whatever `read-lines` does, it keeps its arm reachable from the
enclosing scope. Nothing about the borrow forbids this; the store just chose a
lowering that cannot carry it.

**A second, cheaper defect rides along: the diagnostic misdescribes the cause.**
"argument 'xs' has no tracked phantom state" says the value never had one. It
did — `std/list:len(xs)` at the same level type-checks. The state was lost at a
boundary and the message should name the boundary. The sibling branch in
`phantom_semantic_checker.zig` was already taught precisely this ("say so,
don't blame it for a checker blind spot", the `<state!>` consumption case);
the requirement case beside it still emits the flat sentence. One branch of one
switch learned the lesson and its neighbour did not.

**What it costs downstream, concretely:** `koru-libs/raylib` cannot draw one
rectangle per row. Its `bounce.k` clears the screen and moves entities in a
standing rule, but never renders one, and its header attributes that to the
ambient-context wall on RULES (690_006). That attribution is incomplete — a
lexically nested query arm hits the same dead end by a different path, and the
`for` case shows the dead end is not necessary. Per-entity drawing works TODAY
if the state lives in a `std/grid` and the loop is a counted `for`, because
that path never detaches.

Open: whether the fix is to thread declared phantom inputs into sweep-body
events (which is `bounce.k`'s "parameterized stripe" design note arriving from
the other side), or to stop detaching sweep bodies when the arm captures
anything phantom-typed. The first is more general; the second is closer to what
`for` already does.

## Fixed the same day, and my mechanism guess above was WRONG

The paragraph above says an outer binding "can only arrive as a declared input
— and a phantom-typed one has nowhere to be declared", and calls it a lowering
that cannot carry the borrow. **That is not what was happening.**

The capture threading already worked. `__store_sweepbody_<s>_L<n>` takes the
captures its body references as event inputs, and a plain `i64` bound outside
the arm arrives inside it correctly — one probe settled that and it should have
been the first one run. What the collector dropped was only the PHANTOM:
`lookupBranchIn` read the branch payload's `.type` and `.module_path` and left
`.phantom` behind, so the synthesized input declared a bare type. The checker
then reported exactly what it saw — a name with no tracked state — and was
right to.

Three corrections were needed and each surfaced its own diagnostic, reading
like three unrelated bugs rather than one omission:

- **dropped** → "argument 'xs' has no tracked phantom state"
- **kept verbatim** → KORU033, "Cannot issue obligation `<list!>` on input
  parameter". An input may BORROW a state, never mint one, so the payload's
  obligation has to be demoted — the same demotion an owned column's projection
  already made just above it in the same function.
- **unqualified** → "expected `std.list:list` but got `<prog>:list`". A bare
  `state!` from the author's declaration resolves against the CONSUMER's module
  unless qualified with the one that declared it.

That third one is the reason two spellings of a phantom exist in this file at
all: projections carry the prefixed `mod:!state`, branch payloads carry the
author's bare `state!`, and `bareBorrow` was written for the first and silently
returns the second untouched. A helper that no-ops on an input shape it was
never given is indistinguishable from one that handled it.

**What generalises past this bug:** the lowering was innocent and I spent the
first pass believing it was guilty, because "a detached event cannot capture" is
a satisfying story and I had just watched a detached event lose a chain tail in
`grid.kz`. The cheap experiment that would have redirected me immediately —
*does a NON-phantom outer binding reach the arm?* — takes one file and thirty
seconds. **When a typed thing fails to cross a boundary, first check whether an
untyped thing crosses it.** That separates "the boundary drops values" from "the
boundary drops annotations", and they have nothing in common but the symptom.

`690_252` is green and proves the accumulation, not just the type-check: the arm
pushes and reads the length back, so the output is 1, 2, 3 on the same list.

Still open, and narrower: going through `std/list:new(i64)` — a
`[comptime|transform]` that rewrites to `new-i64` — still fails, because the
collector reads branches off the invocation path and the transform event
declares none. A transform-ordering question, not a phantom one.
