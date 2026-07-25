---
type: belief
id: frag-two-mechanisms-mark-a-transform
provenance: surfaced 2026-07-25 auditing what surface comptime authors actually get; Lars asked why `[transform]` sits on procs at all when the event already declares itself one
ts: 2026-07-25
---

# Two live mechanisms disagree about where a transform is marked, and both are green (belief)

Koru answers "what makes this a transform?" twice, differently, and neither
answer knows about the other.

- **Type-driven, on the event.** `main.zig`'s `generateTransformHandlersToEmitter`
  scans `event_decl`s and infers transform-ness from the tor's **parameter
  types** — `*const Invocation`, `*const Item`, `*const EventDecl`, `Source`,
  `Expression`. Its own comment is explicit: *"the frontend is agnostic to
  `[transform]`/`[derive]` annotations - that's backend dispatch."*
- **Annotation-driven, on the proc.** `emitter_helpers.findTransformProc` scans
  `proc_decl`s and filters `hasPart(proc.annotations, "transform")`. Its doc
  comment states the opposite model outright: *"the event declares the USER
  surface (payload + branch contract), the proc carries the `[transform]`
  annotation."*

## What this produces

The proc annotation is **optional in practice and load-bearing for one lookup**.
`store.kz` writes `~[transform]proc new|zig`; `testing.kz` implements its
transform tor with a bare `~proc test|zig` and is equally green. Nine modules
(io, testing, types, kernel, fmt, list, runtime, taps, liquid_template) carry
transform tors whose procs are unannotated.

Omit it and `findTransformProc` simply does not find your proc. No diagnostic,
no wall — absence. That is the shape this belief exists to flag: a marker whose
omission is silent in one path and fatal in another.

Nothing in the suite reports the disagreement, because **both conventions pass**.
A green board is compatible with either model being the real one, so the
contradiction cannot be discovered by running tests — only by reading both call
sites and noticing they contradict each other.

## Why it is not merely tidiness

Two consequences already observed, not predicted:

- `210_029_transform_requires_comptime` is unreachable **by construction**, not
  merely unimplemented. It expects "`[transform]` without `[comptime]`" to be
  rejected, but its subject (`badTransform { count: i32 }`) carries no AST types,
  so type-driven detection never classes it as a transform at all. The test
  pinned an error that the design had already made impossible. It was found only
  because a harness wall forced every negative test to name its diagnostic.
- `challenges/008` shipped teaching `~[transform]proc` as required — one of two
  conventions presented as the convention. Authored from `store.kz`, which
  happens to be on the annotation-driven side. A doc written from either half of
  a split surface is wrong about the other half and cannot tell.

## Open — this is a ruling, not a cleanup

Which model wins is Lars's call, and the two are not symmetric:

- **Type-driven** makes `[transform]` documentation everywhere and removes a
  silent-omission failure. It also means the *declaration* does not declare
  anything — transform-ness is a property of a parameter list, discoverable only
  by reading types.
- **Annotation-driven** keeps the declaration honest but requires the marker in
  both positions and needs the missing-marker case to become loud.

Related and unresolved: whether `transform` should imply `comptime`. Argued
against on 2026-07-25 because `pre` already exists as a phase modifier
(`~[comptime|transform|pre]`), so a phase axis is open with one inhabitant;
collapsing `comptime` into `transform` would close it before a diagnostics-phase
transform can be spelled. See [[frag-tests-and-compiler-coevolve]] — both sides
are often wrong here and triage is design work.
