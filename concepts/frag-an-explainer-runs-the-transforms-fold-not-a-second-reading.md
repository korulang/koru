---
type: belief
id: frag-an-explainer-runs-the-transforms-fold-not-a-second-reading
provenance: koru session 2026-09-16 — explain landed for real: spine repair + std/refine and std/list explainers; 310_064, 671_018, 671_019 pin the pattern
ts: 2026-09-16
tags: [koru, explain, transforms, comptime, legibility, architecture]
---

# An explainer runs the transform's fold, not a second reading of the program

`std/explain` gives every module a report surface: an `[explainer]` tor
takes `*const std/compiler:Program` and returns a typed `ExplainReport`
(title → sections → notes + properties with int/float/bool/string values).
The command gathers all explainers into one catalog and owns text, JSON,
and HTML rendering — the library produces data, never formatted text.

The discipline that makes it honest: **the explainer calls the same
fold the transform runs.** `explain` executes on the *pre-transform*
tree — it runs instead of compilation, before any `facet_decl` node
exists — so `std/refine`'s explainer walks the same `std/refine` blocks,
the same anchor resolution, and the same meet that the transform would
emit. `metFields` is the fold as a comptime API: a consumer's explainer
(`std/list`, later `std/store`, a JSON decoder) asks "what does this
type's facet meet to" and gets the same `[]Field` the transform emits —
one producer, several sinks, no drift. An explainer that re-interprets
the source is a second transform and will lie.

The pre-transform placement is a feature, not a limitation: it is the
only surface that can explain a program that refuses to compile.
`671_019` pins it — an orphan refine and a bound on a `string` terminal
each report `refused: <reason>` while the compiler's own diagnostic says
the same thing. "Why did my program refuse?" is the highest-value query
explain can answer.

Two corollaries observed while landing it:

- **The consumer's explainer correlates by identity, not linkage.**
  `std/list`'s explainer doesn't know refine; it calls
  `koru_refine.metFields` when the module exists and reports "pushes
  unchecked" when it doesn't. The two reports join on `home:Name` in
  the catalog — how "who enforces this?" stays honest without refine
  knowing its consumers.
- **Reports read the declared vocabulary, not the lowering.**
  `port: Port & >1024` reports `Port` and resolves `Port → i64` for the
  scalar property — the user reads what they wrote, the tool reports
  what it resolves to.
- **A name-composing transform's fold is its sites, not its output
  decls.** `std/pump`'s `run` enumerates joins by scanning generated
  `__pump_<name>_step_<i>` decls — which don't exist at explain time.
  The explainer's equivalent fold is the *document order of the
  `std/pump(...)` sites themselves*, checked with the same legality
  rules (step required, `! wait` needs `! live`, callee contract via
  `PH.calleeDecl`). Same membership, same order, same refusals — a
  different enumeration surface because the wire it reads is the
  program, not the product.
- **Refusal wording is shared, not mirrored.** `std/pump` keeps every
  KORU161 text in a `PM` const block (`pump.messages.kz`); the
  transforms pass them to `ast.refusal` and the explainer formats the
  same consts for `status` rows. The report for a refusing program is
  the diagnostic verbatim — one string, two sinks, and no way for the
  explanation to drift from the error it explains.
- **A synthesized callee is named by its generator, never refused as
  undeclared.** Pre-transform, `tasks-step` is nowhere — the store's
  `! step` arm mints it. `std/pump`'s explainer keeps a `PS.synthesized`
  probe (`pump.synth.kz`) that recognizes `<store>-<verb>` against the
  `std/store:new` sites carrying the arm, and reports the callee as
  `← synthesized by std/store:new(tasks)`. Demand a decl for a
  generated name and explain disagrees with the compiler on a program
  that compiles — the one failure mode the whole design exists to
  prevent. Which means the *generated-name channel is a contract two
  explainers corroborate*: store reports "exposes tasks-step", pump
  reports "tasks-step ← synthesized by std/store:new(tasks)" — the
  catalog traces a name that exists in neither source tree.
- **"Declared but not enforced" is a reportable fact, not an absence.**
  `std/store`'s explainer asks `koru_refine.metFields` what a member
  proto carries and then says plainly that `insert` stores unchecked —
  `facets_declared = 2` next to "insert does NOT enforce". The gap
  between declaration and enforcement is exactly what a reader needs;
  silence would pass for "no facets exist."
- **A plan is a fold result, and the fold's input surface is the
  transform's, not the organ's.** `std/store`'s explainer reports per
  query site whether `! first` routes to the declared index or sweeps —
  by running the query transform's own chain (arm resolution, request
  rules, guard lowering, `firstRoute`) and never by reading the `when`
  text. The trap found landing it: the columns fed to that chain must be
  the columns the *transform* can see, not the columns the *cell* holds.
  A `[tree]` store's synthesized `parent` exists in the cell and is
  invisible to `query`'s read surface; appending it "for completeness"
  would have explained a plan for a guard the compiler refuses — the
  inverse of the drift this concept bans, and just as much a lie.
  Corollary: a report row that repeats per site (`query[0]`, `query[1]`)
  is indexed in its key, because a section renders as one JSON object
  and a repeated key silently drops rows.
- **Open:** the plan fold lowers the guard, not the body. An unknown
  field referenced only in a query body refuses at compile time while
  explain still reports a plan for the site. Closing it means running the
  body rewrite on a clone at explain time; whether that cost is worth
  paying is undecided.

## Evolved 2026-09-21 — the clone-run is worth it where the transform retargets

`std/supervisor`'s explainer (`supervisor.explain.kz`, pinned by
`320_168_supervised_explain_reports`) is the strongest form of this
discipline: the derived rows (producer, vocabulary, step signature,
policy, scope lift) read the same surfaces the transform reads, and then
the `elaborated` section **clones the program, runs the real transform
pass over the clone, and prints the generated step decl + retargeted home
flow through `ast_printer.printItemSource`**. For a `retarget_producer`
transform this is the difference between describing and showing: the
rewrite happens to a call the user wrote, so only the transform's own
output can prove what the call became. The printer refuses nodes with no
surface spelling — which is also honest information about what the
elaboration produces.

Mechanics that made it work: `run_pass`/`process_all_transforms` is a
file-level decl in the emitted backend — reachable from an explainer proc
as `@import("root").process_all_transforms` (the extern-shim path). A
minimal `CompilerContext` with a fresh `ErrorReporter` satisfies
transforms that declare `reporter:` — `hasErrors()` is the refusal
signal. `site_hash` indexes invocations, not continuations, so a site
witness is the `|> supervised` invocation's pointer. Generated names
(`__sup_step_L<line>`) are mintable in the explainer from
`site.location.line` — the transform derives them the same way, so the
explainer can find its items in the elaborated clone by name.
**2026-10-29 — the elaborated print is partial by design.** The second
explainer to run the pass for real (`std/store`, 690_378) surfaced the
boundary: `ast_printer.printItemSource` does not spell every item
`process_all_transforms` emits. Items carrying transform-produced
fields refuse — `std/store:new`'s site dissolves to `inline_code`
("emit-only IR"), and the minted `__store_sweepbody_*` impl flow trips
`flow inline_body (transform-produced)`. An elaborated section must
catch `UnprintableNode` and report it — the unspellable item is the
finding (a shape the compiler writes that the surface cannot carry),
not a defect of the report.
