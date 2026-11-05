# Assay — capability manifests at compile time

- **Date**: 2026-11-05
- **Tree**: `be207a5c3`+ (assay-caps worktree, main)
- **Target**: capability-assay — *what would it take for a Koru module to
  declare and enforce its capability surface at compile time?* (the
  ConnCaps design space: a module says which capabilities — fs, net, env,
  clock, exec — it may use; the compiler refuses undeclared use).
- **Contestant**: devin (seat snow-yarrow @ w1C:p4T), 2 of 3

## The shape of the question

A capability manifest has three parts: a **declaration** (the module names
the caps it claims, and caps attach to the surfaces that consume them), a
**collection** (something reads the merged program and computes the used
set), and **enforcement** (a compile-time refusal when use > claim, with a
named diagnostic). The map below scores each part against what the tree
already ships. All claims cite a surface or a probed refusal.

## Exists

| # | Surface | Evidence |
|---|---------|----------|
| E1 | **Module-level declaration items that never execute, harvested post-parse.** `~flag.declare { "name": "release", … }` is a `[comptime\|norun]` item: it does not run; the frontend harvests it after parse and the harvest feeds enforcement (unclaimed bare flag atoms refuse — 310_145). This is exactly the manifest-item shape a `cap` declaration wants. | `koru_std/compiler.kz:717-754`, `koru_std/compiler.commands.kz:14` |
| E2 | **Annotation-gated imports evaluated at compile time.** `~[command(explain) or command(help)]import std/explain` — the gate's atoms resolve through a provider chain (`command=`, flags, env, `build:config`); "no entry true" excludes the import. A capability-shaped gate ("import only if granted") is already the mechanism, just not the atom. | `koru_std/compiler.commands.kz:7`, `src/comptime_eval.zig:1242-1290` |
| E3 | **Compile-time program introspection + custom refusal.** `[comptime\|transform]` tors receive `program` (the merged AST), `invocation`, `item`, `reporter`; `std/tree:mint` walks module items (`findNodeDecl`), validates, and refuses via `ast.refuse` with a named diagnostic (KORU184). So a check that reads a module's declared surface and refuses exists end to end. | `koru_std/tree.mint.kz:16-41,87-118`; refusal pins 682_005/006 |
| E4 | **A module-level declaration registry.** `std/tree:node(Node) {…}` registers kind=node in a shared registry at comptime; `mint` validates call sites against registered fields. The declare→collect→enforce loop already runs in production. | `koru_std/tree.registry.kz`, `koru_std/tree.node.kz` |
| E5 | **Per-value compile-time enforcement.** Phantom obligations (`*T<state!>`) are checked across the whole program with auto-discharge — the custody analog of capability tracking, already enforced, already diagnostic-named (KORU030). | `AGENTS.md` store/obligation surface; 335_050/051, 690_* pins |
| E6 | **Arbitrary annotation text parses.** Probe (this session): `[cap(fs)]pub tor hi {}` in a `.k` file → `✓ Shape checking passed`. A cap spelling on tors/imports needs no grammar work — annotation entries already evaluate through the provider chain. | probe `scratch_cap_probe.k`, `-c` green |
| E7 | **Runtime capability enforcement.** `koru-libs/koru` is a sandboxed interpreter: scripts call only scope-registered tors, unregistered calls refuse `EventDenied`; the boundary is "the tors literally don't exist." `koru_std/bridge.grants.kz`/`hostverbs.kz` grant host verbs per session. Capability *enforcement* exists — at runtime over interpreted flows, not compile time over the host program. | `~/src/koru-libs/koru/README.md`, `koru_std/bridge.grants.kz` |
| E8 | **Surface enumeration.** `koruc <file> glance` prints every event's signature/annotations; `ast_json` round-trips the merged AST — the inventory machinery a collector needs is shipped. | toolchain skill, `src/ast_json.zig` |

## Missing-blocker

| # | Gap | Proof |
|---|-----|-------|
| B1 | **An unconditional module-level enforcement hook.** Every existing enforcement fires at an *invoked site* (`[transform]` runs when its tor is called) or inside a *compiler-wired sink* — `claimed_cli_flags` in `comptime_eval.zig:1277` is a per-invocation audit sink hardcoded for CLI flag atoms. There is no surface for a module to declare "run this check over my merged AST at compile time" without a call site invoking it, and no slot for a `cap()` atom to claim into. A capability check that only runs when called is a linter by opt-in, not a manifest. This is the commission item: a cap-atom sink + an unconditional check pass in the pipeline (`koru_std/compiler.kz` pass list is compiler-owned — purity_analyzer, dead-strip, transform runner are wired in `src/compiler_passes/`). | cited: `src/comptime_eval.zig:1277-1290` (sink is flag-atom-specific); `koru_std/compiler.kz` pass wiring |
| B2 | **Provider-atom extensibility.** Gate atoms resolve through a *fixed* provider chain (flags, `command=`, env, `build:config` — `comptime_eval.zig:1242-1290`). A `cap()` atom kind is not in the chain, and `ast_functional.zig:3398` warns atom kinds must reach every boundary or the grammar drifts — new atoms touch multiple sites. Not a parse problem (E6); an evaluation problem. | cited: `src/comptime_eval.zig:1242-1252`, `src/ast_functional.zig:3398-3412` |
| B3 | **Any capability surface in orisha.** Grepped `lib/ctx.kz`, `lib/index.k`, `lib/pump.kz`, `lib/index.kz`: every `cap` hit is a byte-limit cap (header caps, fd caps), zero capability/grant machinery. ConnCaps consumers would be new code, not a migration. | cited: grep over `~/src/orisha/lib` (read-only survey) |

## Missing-but-portable

| # | Item | Why portable |
|---|------|--------------|
| P1 | **Cap declarations on tors/imports.** `[cap(fs)]` parses today (E6). Declarations are data a collector can read off `program` items — no new grammar, no new spelling invention needed beyond Lars's name choice. | probed parse + annotation evaluation chain |
| P2 | **Transitive cap computation.** A transform/comptime tor can already walk the merged `program` (E3 precedent: `findNodeDecl`, `TerminalRef_scopeOfFlow`). The used-cap set computation is ordinary pass logic — portable the moment B1's hook exists; dead code until then. | exists machinery, missing trigger |
| P3 | **Signal/vocabulary.** `capability`, `capability-growth`, `capability-added`/`capability-gained` signals already registered in `~/src/koru-libs/signals/` (one auto-orphaned, "declared before defined" — worth one consolidation note when this lands). | cited files |

## Recommendation

**Commission it — as a compiler feature, not a stdlib surface.** The
declaration half is already spelled by two shipped mechanisms
(`flag.declare`-style harvested items, `[…]` gate annotations); inventing
a new manifest grammar would duplicate them. The real gap is narrow and
named: **(a)** a `cap()` atom kind in the provider chain + a claim sink
(B2, multi-site but bounded — flag atoms are the worked precedent), and
**(b)** an unconditional check pass that reads `program`, intersects
used-vs-claimed caps, and refuses with a named diagnostic (B1, one new
pass in the existing pass list). The refusal machinery (E3) and the
declaration surfaces (E1/E2/E6) are already green.

Cost class: **compiler feature — medium.** Touch points: annotation atom
kinds (`ast_functional`), the provider chain + claim sink
(`comptime_eval`), one pipeline pass (`compiler.kz`/`compiler_passes/`),
negative pins under a 6xx cluster. No stdlib grammar, no new file forms,
no host ABI. ConnCaps then rides on top as ordinary `[cap(…)]`
declarations — orisha has nothing to migrate (B3), it gains a surface.

*Not commissioned here:* the runtime analog (E7) already serves the
interpreter; the compile-time manifest is a different axis and should not
be conflated with it in the same commission.
