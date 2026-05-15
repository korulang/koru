# Purity in Koru

Koru tracks purity in three layers. Confusing them produces design errors.

## Layer 1 — Language facts (structural, not configurable)

These are TRUE about Koru regardless of any compiler pass:

- **Events are always locally pure.** Events are interface declarations — they have no body, no execution, no side effects. An event is a contract, like a C# interface.
- **Subflows are always locally pure.** Subflows are pure composition of event dispatches. The composition itself has no side effects; effects come from what gets dispatched.
- **Procs are locally impure by default.** Procs contain Zig code, which is opaque to Koru's analysis. The compiler must assume the worst.

There is no "undeclared" third state. A proc without `[pure]` is structurally impure under the assume-Zig-is-opaque rule. That's a derived fact, not absence of information.

## Layer 2 — Compiler feature (always-on tracking)

Given the structural facts of Layer 1, transitive purity is **derivable without any annotation at all**:

- Event purity = AND of all impl purities (each impl is a proc or subflow)
- Subflow transitive purity = AND of dispatched events' transitive purity
- Cycles handled via fixed-point iteration

This is a built-in capability of the analysis pipeline, not opt-in. It runs in Stage C as part of the metacircular pipeline's `analysis` segment (`koru_std/compiler.kz`, the `check_purity` step). Implementation lives in `src/purity_checker.zig`.

Procs are leaf nodes in the call graph — they do not dispatch events back into the event system. The graph is over events and subflows only.

## Layer 3 — Annotations as developer-supplied refinement

- **`[pure]` on a proc** = developer assertion: "this Zig body has no observable effects." This is an **escape hatch for the optimizer**. The optimizer normally cannot optimize across a proc boundary because Zig could do anything. `[pure]` opens that door — "trust me, optimize across this." Lifts the assume-impure default for that one proc.

- **`[effects(io|net|...)]`** is FUTURE work — not yet built. Refinement, not escape hatch. Tells the optimizer specifically what side effects exist, enabling reordering against unrelated effects. `[pure]` becomes shorthand for `[effects()]` when this lands.

- **Annotation positions are open at the frontend.** `[pure]` on an event is redundant (events derive purity). `[pure]` on a subflow is redundant-but-true (subflows are always locally pure). Neither is rejected. Annotations are opaque metadata; compiler passes interpret what they care about and ignore the rest. This is the same pattern as source blocks — Koru's "you are the compiler" design generalizes to all annotation work.

## Verification surface — TBD

The user-visible signal — what concrete behavior fires when the purity tracker classifies something — is not decided yet. Current state:

- `purity_checker.zig` propagates flags but emits no compile errors.
- The flags are consumed downstream by `tap_transformer` and `emitter_helpers` (optimization).
- The test framework has a separate mock-requirement check that errors on impure events called from `~test` blocks without mocks. That is user-visible but not the canonical surface for purity verification.

The verification surface (errors, warnings, optimizer behaviors that depend on purity) is a future design conversation. For now, propagation runs internally and the flags are available for downstream consumers.

## Tests in this directory

The tests here are demonstrations of the model. Each one exercises one structural fact and verifies the corresponding `is_pure` / `is_transitively_pure` flags propagate correctly into the emitted backend AST. The verification mechanism is `post.sh` greps over `backend.zig` (where the AST is emitted as Zig literals) — not the in-Koru test framework, not invented compile errors.

This means the tests survive future decisions about the user-visible signal. They verify the propagation, which is the foundation; whatever enforcement mechanism we wire up later sits on top of these flags.

## What's NOT covered yet

- Cyclic call graphs (need a clean way to set up A↔B mutual dispatch)
- Multi-impl events (event with both pure and impure impls)
- Effect-based annotations (future)
- Verification surface (errors / warnings / optimizer-driven differences)
- `[opaque]` proc combination (see `410_011_opaque_procs/TODO`)
