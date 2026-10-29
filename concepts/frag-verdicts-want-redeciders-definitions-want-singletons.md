---
type: belief
id: frag-verdicts-want-redeciders-definitions-want-singletons
provenance: building verify/semantics/FlowKernel.lean next to verify/witness/WitnessCheck.lean — two Lean artifacts that look symmetric and are not; the asymmetry is the point
ts: 2026-10-17
---

# Verdicts want re-deciders; definitions want singletons (belief)

The verification branch carries two Lean surfaces that look like the same
move and are opposites:

- `WitnessCheck.lean` is a **re-decider**: the compiler prints witness
  claims, the oracle independently derives the verdict again. Two
  implementations, and their possible disagreement is the mechanism — a
  forged or drifted claim fails because the second decider does not
  follow the first.
- `FlowKernel.lean` is a **singleton**: the mechanized flow-graph
  evaluator does not re-decide anything. It IS the semantics. There is
  deliberately no second evaluator to cross-check it against, because a
  semantics that exists twice is not checked — it is two candidates and
  a coincidence.

**The durable claim: independence is the doctrine for claims, not for
definitions.** Re-deciding a *verdict* buys you a wall — disagreement is
a refusal surface. Re-deciding a *definition* buys you nothing — two
evaluators that agree today are two places the semantics can drift
tomorrow, and when they disagree you have learned there is a bug
somewhere but not which artifact is wrong, because neither is the
referent. The referent for a definition has to be singular: one
evaluator, kernel-checked, against which every implementation (koruc's
runtime, the C emitter's compiled output) is a *claim* to be verified —
and claims get re-deciders.

This is why the fuel-bounded evaluator in FlowKernel ships with
`evalNode_mono` rather than a second engine: more-fuel-never-flips is
what makes the bound a resource limit instead of a second semantics.
If fuel could change a decided answer, the fuelled evaluator and the
unfuelled "true" semantics would be the two-candidates problem all over
again, with the disagreement hidden inside one file.

## Where this could be wrong

- A singleton semantics is only as good as its fit to the implementation
  it claims to define — **measured, not merely predicted.** A
  clause-by-clause audit of FlowKernel against `comptime_eval.zig` found
  seven real divergences, all model-side (void-dispatch refusal,
  catchall tagged-dispatch, `and`/`or` short-circuit, truncating `/` `%`,
  floored `@mod`, `++` vs `+`, lazy `@as`): the kernel WAS a clean model
  of a slightly-wrong language, and every fix moved the model toward the
  implementation — divergence was a bug with a referent, exactly as
  predicted. `FlowCheck.lean` re-decides `[flow-eval]` whole-program
  claims end to end, and the emit leg has now landed:
  `comptime_eval.zig` serializes one claim per interpreter-consumed
  walk under `std/witness:enforce` (graph + entry args + fuel
  certificate + result-or-refuse + thunk oracle leaves), with
  `[flow-eval-skip]`
  markers for walks outside the kernel subset so silence is never
  ambiguous. Real claims re-decide MATCH; a hand-forged edit to a real
  claim's result MISMATCHes — the disagreement surface works on live
  output, not only on fixtures. `310_141` pins the round trip. The fuel
  field is a certificate in the strong sense: the walker counts one
  increment per kernel `run` call along the derivation spine, so the
  emitted number IS the measured proof depth — not a padded bound. The
  move that made this cheap: you don't need ISAR's static
  `sufficient_fuel_correct` to stop guessing — when the instrumentation
  is isomorphic to the checker's cost model, the walk reports its own
  depth, and every undercount fails loud (fuel exhaustion is `none`,
  never a wrong yes). What remains unproved is the isomorphism itself —
  corpus-pinned, not theorem-pinned. The checker itself now carries its
  spec: `WireOk` is the wire relation, and `checkLine_{sound,complete,
  reject,none}` prove the executable answers MATCH only inside it —
  the ISAR `step?`/`IStep` shape. Two honest discoveries from that rung:
  `Float` has no lawful decidable equality (IEEE `+0.0 == -0.0`), so the
  relation's verdict-equality *is* the checker's `==` — attempting
  `decide (· = ·)` was the two-candidates trap in miniature, proposing a
  stricter equality the corpus never agreed to; and the unproved residue
  is decoder fidelity — `WireOk` talks about the *decoded* claim, and a
  misdecoding `sxArm` would verify the wrong claim consistently. That
  lemma belongs to `FlowDialect`'s encode/decode preservation.
  The re-decider shape then grew past the verdict: A.5 put the flow's
  residue arms on the wire, so the kernel re-decides the *observable*
  too — `renderObservable` re-dispatches the result into the residue
  (`spliceResidue`'s own rule, not a second reading) and renders the
  print nodes, and `--cref` compares that derivation against the
  emitted C's actual `__koru_stdout_write*` sequence. The graph→C seam
  is thereby checked per instance — the emitter's runtime observable
  is verified against an independent derivation of it, which is the
  translation-validation half of the channel. `310_142` pins the pair:
  verdict MATCH and `cref: refined` on one compile. What A.5 does NOT
  yet do: refuse the *absence* of residue coverage — a claim with
  `(residue)` arms the renderer can't read just fails the marked test,
  but nothing checks that every emitted flow function got a claim
  (the zip is count-strict per corpus, which is the current guard).
- The claims-prover's verdicts joined the corpus discipline in two
  legs. First the ledger: under `std/witness:enforce`,
  `pass-claims-check` commits `[claim-check]` + `[claim-census]` and
  `verify/claims/ClaimsCheck.lean` re-decides vocabulary, detail
  discipline, census honesty, and splice drift. Then the judgment
  itself: the pass now commits the FM **pre-image** — `[claim-term]`
  per tried candidate, `[claim-goal]`/`[claim-head]`/`[claim-edge]`
  per honors site (goal, entry rows, per-case arm premises +
  rebinding substitutions) — and the checker's port of
  `spec.linear.kz` rebuilds the meets and re-runs integer-tightened
  Fourier–Motzkin under the same fences. `proven` now means the
  committed rows entail it; a verdict disagreeing with its own
  evidence is a violation in both directions. The last piece is
  genuinely re-decided — but the boundary moved, not vanished:
  the checker verifies **verdict-follows-evidence**, while
  **evidence-follows-AST** (that the committed rows mirror the
  program's real arm premises) is still asserted by the pass — the
  wire is now the trusted channel, and that is stated in the file
  header rather than absorbed. Pins: `675_036` plus enforced arms on
  `675_008`/`675_009`/`675_010`/`675_012` covering every verdict
  class; `tampered.txt` catches a well-formed-but-unentailed
  `proven`.
- The doctrine now spans **command-produced** verdicts. Commands are
  solvers: koru-os's `realize` commits admission/declaration verdicts
  through `emitter_helpers.commitCommandMark` — a validated sink, not a
  text writer — and the backend flushes `<stem>.marks` after dispatch,
  before honoring `command_exit_code`. The asymmetry is preserved on
  purpose: `Invocation.marks` stays pass-produced internal state, while
  the command channel mints a *named artifact* whose line format lives
  in the channel, never in command code. `WitnessCheck.lean` then
  re-decides the artifact as just another corpus — `admission`/`declaration`
  joined the relation vocabulary, and the corpus-level law (one verdict
  per (site, arm) per run) is checker-enforced. A command's verdict is a
  claim, so it gets a re-decider — same wall, wider door.
- The same doctrine closes the M→V gap at the artifact boundary:
  koru-os's `realize matrix` now commits the *catalog* itself as marks
  (`catalog` rows: `declared_by=` + `binds=`) alongside the derived
  `projection` cells (`bound=<n> total=<m>`). The printed `n/m` cell
  was trusted output; committing the input data lets `projectionCheck`
  RECOUNT the transform instead of re-printing it — the projection is a
  checked transform, not a believed one. This is the pattern Path B
  wants for artifact re-decision generally: don't trust the derived
  surface, commit the pre-image and recount.
- The same pre-image discipline reached K2 Use B: `pass-dead-strip` is
  the first transform whose semantic justification is itself a
  decidable relation — lawful removal IS set membership, `removed ∩
  (uses ∪ roots) = ∅`. Under enforce it commits `strip-use` (every key
  the membership test consults, text-scraped spellings included),
  `strip-root`, `strip-rm` with BOTH probed keys, `strip-cargo`
  digests, and a `strip-census`; WitnessCheck re-runs the membership
  law rather than trusting the pass. Two teachings it surfaced on
  first contact: the corpus is only honest when it is all-or-nothing
  (the caller swallows a failed pass, so evidence buffers and prints
  solely on success — a half-ledger would read as drift), and
  removing-decl-keys legitimately repeat (welded modules carry
  same-named decl objects) — set-key uniqueness applies to uses and
  roots, never to removals. It also caught a real derivation gap in
  an adjacent rule the same week: the registry normalizes a bare
  `-> T` return to a canonical `ok` branch, which the descriptor
  checker had to learn before `430_069`'s emit row could re-decide.
- The committed pre-image's own trust boundary broke the same week it
  was named: a pass that commits a *partial* `used` set passes every
  committed-set law while licensing unlawful removals. The fix was the
  channel, not more ledger: `program.ast.json` — the serialized
  frontend→backend artifact the backend deserializes as
  `original_ast` — carries the whole pre-image already, so
  `verify/strip_ast/strip_ast_check.py` re-derives it with a
  from-scratch walk and re-decides the ledger against the derivation:
  every artifact-spelled key must be committed, no removal may name an
  artifact-spelled path or exceed a decl's multiplicity, cargo must
  match the host-line multiset, and under `koruc lib` roots must equal
  the pub decl set exactly. Verdicts want re-deciders — and a
  committed pre-image wants an independently-derivable one, or the
  ledger merely moves the trust from verdict to ledger. The artifact,
  not the pass, is the channel. Two boundaries it measured open
  rather than assumed: the pass filters the post-transform tree, so
  transform-introduced decls (`690_380` shows 14) are uncheckable from
  this channel — and the same artifact carries the arm premises K3
  claims commit, so the pattern generalizes but only the strip side
  is wired. A second correction first contact surfaced: root-seeding
  evidence must commit per qualifying export, not per set insertion —
  a pub already impl-marked is still a root, and insertion-coupled
  evidence reports a lib's root count as zero.
- The same independence rule reached the transform delta itself:
  `program.ast.json` cannot carry a whole_program write-back's
  pre-image (it predates the transform), and a handler that computed
  its own `+added/-removed` would be self-certifying — the delta is
  measured by the runner, the only party holding both trees, and
  committed on the app line as `sitepath=`/`inv+=`/`inv-=`. The third
  oblige atom `consume-only` re-decides `inv- ⊆ {sitepath}` against
  it — the invocation-level analog of matched-only (kinds bound item
  moves; this bounds which *call paths* vanished). Measuring before
  declaring caught the honest shape: tap's real delta is only the
  consumed call — the law `inv- ⊆ {site}` is what the corpus supports,
  not the stronger `==`, because a transform that never removes its
  call is still lawful. Same doctrine, one level down: evidence a
  transform could compute about itself is not evidence.
- There is a defensible middle: two mechanized semantics with a proved
  equivalence (a definitional and a denotational reading, as in textbook
  PL formalizations). That is one semantics stated twice and *proved*
  equal — the proof is what makes it safe. The claim is against two
  unproved-equal definitions, not two presentations.
