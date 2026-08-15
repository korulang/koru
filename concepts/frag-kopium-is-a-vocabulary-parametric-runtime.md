---
type: belief
id: frag-kopium-is-a-vocabulary-parametric-runtime
provenance: 2026-08-13 session — the KOPIUM arc resolved into a stance; spec in github.com/korulang/kopium (KOPIUM_RUNTIME.md)
ts: 2026-08-13
---

# KOPIUM is a vocabulary-parametric runtime: a register block parameterizes grammar, prompt, enforcement, and compiler — bespoke, derived, never authored (belief)

An agent whose only tool is Koru on a resource bridge reaches its final shape
not by widening one universal interpreter but by parameterizing the runtime
with the vocabulary. Hand the runtime a `register` block and it *becomes* an
interpreter for that world: the wire grammar, the prompt, the possession
enforcement, and the growth mechanism (defined flows lowered by a bespoke
compiler) all derive from the declaration. One spec, four derived things. The
same binary runs a notes-agent, a git-agent, a math-agent; the vocabulary is a
parameter, not a fork.

Two load-bearing constraints keep this cheap instead of fragmenting:

- **Derived, never authored.** A bespoke interpreter/compiler is generated
  from the register block, never hand-written per domain. Hand-authored
  engines collapse cheapness into fragmentation.
- **Terminating vocabularies.** A finite verb set with bounded composition is
  what makes the bespoke flow-compiler small enough to live in the runtime —
  compiling one defined flow is a bounded lowering, not a program recompile.
  Agent vocabularies are tool surfaces, and tool surfaces are terminating by
  nature. Unbounded vocabulary is a refusal, not a feature.

The growth mechanism is the REPL: the bridge `run` loop discriminates
declaration from invocation, definitions land in the session environment, and
the derived prompt walks that environment so the agent sees its own inventions
next turn. The environment also grows by **runtime import**, the way every
REPL's does: `std/runtime:import("my_dumb_library")` installs a vocabulary
unit — a register block plus flows over the base, **no compiled code** — into
the live session. The "dumb" constraint is load-bearing: flow-only libraries
need no compilation, so they import live; libraries with procs (new side
effects) are compile-time, or the rare gated native-module path. Runtime
import and REPL-define are one mechanism — installing flow-units into the
session — at two granularities: one flow inline, or a unit of many.

The environment is **permanent, as a directory**: the bridge's world is a
folder, the vocabulary IS the flows on disk, defining writes a file, importing
reads one, and the derived prompt walks the directory. Permanence is free
because the filesystem is permanent — the agent's growth is cumulative across
sessions, and the growth mechanism uses the SAME verbs as the agent's ordinary
work (open/append/close on the world file): the meta level and the object
level are one. The line that keeps it safe: **definitions persist, possession
does not** — vocabulary is durable capability; held resources stay
session-scoped and re-acquired. Persisting possession is the
ambient-resources failure; persisting vocabulary is cumulative
self-improvement.

R1 (the REPL define) is LANDED and pinned: `std/bridge:define` installs a
subflow declaration into the session's durable defined-flows table; a later
`run` dispatches it with params bound and every body call through the same
possession machinery. Pinned at 440_008_runtime_define — the belief's
growth-mechanism half is now code, not prose.

New side effects are the one thing flows cannot create — they are
compiled primitives, grown by the platform at build boundaries, with a rare
gated native-module escape hatch for mid-session needs.

What would correct this: a vocabulary that cannot be served by derivation (a
domain needing hand-written grammar or lowering), or a terminating-vocabulary
bet that fails in practice (agents routinely needing unbounded expression) —
then the runtime must grow a general compiler and the cheapness claim dies.

Related: [[frag-a-scope-must-describe-its-own-vocabulary]] — the derived prompt
is the earlier belief, generalized from one surface to the whole runtime.