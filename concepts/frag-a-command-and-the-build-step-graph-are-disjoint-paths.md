---
type: belief
id: frag-a-command-and-the-build-step-graph-are-disjoint-paths
provenance: building koru/github (2026-08-22) — a site that both declares `std/build:step`s and floats a `[comptime|command]`; fixed in main.zig, pinned 310_124
ts: 2026-08-22
---

# A `[comptime|command]` and the build-step graph are disjoint paths, and the graph can silently swallow the command (belief)

A `[comptime|command]` is dispatched by `koru_command_dispatch` at the END of
the build, AFTER the frontend has already had its say. The build-step graph
(`std/build:step` + `depends_on`, collected by `collectBuildStepCandidates` and
topo-sorted by `resolveBuildSteps`) is executed by the FRONTEND, and when a
program declares user-defined steps the frontend runs them and **returns early**
— before command dispatch ever sees the verb.

So a program that declares steps AND floats a command is self-contradicting:
`koruc site.k some-command` silently ignored `some-command` and ran the steps
as if the command did not exist. The command was swallowed, not refused.

`ci` is the shared verb that resolves the tension. It special-cased in the
frontend to drive the graph: a plain build runs the graph, `ci` runs the graph,
and every OTHER command still dispatches to its backend handler. That makes the
step graph the "run the whole unit" surface, and `ci` the portable entry a
koru/github or koru/vercel pipeline can call — one vocabulary (`std/build:step`
+ `depends_on`), shared across host surfaces.

## Why it stayed invisible until now

The graph self-executes only once a program declares a step of its own — a
default-only `std/build:step` graph does not auto-execute (they are just
available for override). The one test that exercised the chain (310_033)
overrides compile_backend/build/run with echoes, so it never sat beside a
command in the same program. Command tests (310_103, 310_053, 310_055) declare
no steps. The overlap — steps + command in one program — was untested, which is
why a code path that ran the wrong thing for exactly that shape stayed green.

## The tell and the fix

The tell is the same class as `writeBranchName` (main.zig:39): two writers that
mangle/spell the same identifier differently, silent until a kebab name crosses
a module boundary. Here the two paths are the frontend step executor and the
backend command dispatcher; the fix was `drives_step_graph` — a guard in the
frontend's early-return that lets `ci` through, and the `mangleHandlerName`
that lets a kebab-named command (`publish-npm`) emit a valid handler symbol.

## Scope / not-yet

- Only `ci` is granted graph-driving; the rule for other commands is "not the
  frontend's job." If a second frontend-reserved verb is wanted (e.g. `all`),
  it is the same one-line special-case.
- `std/build:run_step` is still a doc comment, not a wired tor — a `ci` whose
  handler runs in the backend cannot call it. The graph executor lives in
  `main.zig`, so the frontend-reserved-verb approach is the honest one for now.

Related: [[frag-generate-command-separate-emission-regime]] (a command breaks
OUT of the pipeline — the mirror case), [[frag-runtime-build-graph-duplicates-build-zig]]
(a duplicated build graph that drifts).
