# KOPIUM Runtime — a vocabulary-parametric agent bridge

Status: stance committed 2026-08-13. The governing design for the KOPIUM
agent runtime. Every subsequent piece of work either serves it or is measured
against it. Evidence this session: `scope-vocabulary` (430_057), the
prose-is-not-an-invocation fix (430_055), the flow-param store-shadow fix
(690_271), and the kopium-headless derived-prompt wiring.

## The stance

KOPIUM is not an interpreter with a vocabulary bolted on. It is a
**vocabulary-parametric runtime**: hand it a `register` block and it *becomes*
an interpreter for that world — its wire grammar, its prompt, its enforcement
table, and its growth mechanism are all **derived from the declaration**.

One declaration, four derived things:

| derived surface | status | where |
|---|---|---|
| **Enforcement** — possession, budget, teardown | DONE | the bridge today (`std/bridge`, the `register` transform, `assertHandlesHeld`) |
| **Prompt** — the agent's world, byte-identical to enforcement | DONE | `std/runtime:scope-vocabulary` (430_057), consumed by kopium-headless `wire.kz` |
| **Grammar** — a restricted, terminating wire grammar per vocabulary | TODO | rung R2 below |
| **Flow-compiler** — defined flows lowered to native handlers | TODO | rung R3 below |

The same binary runs a notes-agent, a git-agent, a math-agent: the vocabulary
is a parameter, not a fork.

## The guard: derived, never authored

Bespoke interpreters and compilers are cheap **only if they are generated from
the declaration, never hand-written per domain**. The `register` transform
already derives a dispatcher from a register block; the same mechanism must
derive the restricted grammar and the flow-lowering. "Bespoke" never means a
new engine per vocabulary — that collapses cheapness into fragmentation.

## The bet: terminating vocabularies

A **terminating vocabulary** — a finite set of verbs with finite signatures,
bounded composition — is what makes the bespoke compiler small enough to live
in the runtime. Agent vocabularies are tool surfaces, and tool surfaces are
terminating by nature. The bet: the agent's defined flows over such a
vocabulary are bounded compositions, so compiling one flow at definition time
is a bounded lowering through a compiler that fits in the runtime — the
"summonable recompile" resolved as compiling one flow, not recompiling a
program.

If a vocabulary stops terminating (arbitrary recursion, general expressions),
the bespoke compiler becomes a general compiler and cheapness dies. The
constraint is the design; it is not optional.

## The growth mechanism: the bridge run loop is a REPL

A normal interpreter discriminates `def` from expression. `std/bridge:run`
must do the same:

- **Invocation** → dispatch (today's behavior).
- **Declaration** (a subflow definition naming a tor) → **define into the
  session's environment**. The defined flow is callable on subsequent turns.
  No register ceremony: the definition IS the registration, exactly as `def` is.

State that persists across turns already lives in the session (transcript,
reply, bridge-held resources); defined flows join it. Nothing in module memory.

Definition-time analysis — the one piece a normal interpreter does not need,
because Python has no type system to lie in:

1. **Obligation honesty**: the declared signature's phantoms must match what
   the flow's body actually creates/discharges, computed statically from its
   invocations. A definition whose declared spec does not match its real
   behavior is refused.
2. **Scope filtering**: every event the flow invokes must be within the scopes
   the session holds.

The derived prompt walks the session environment — compiled scopes plus
defined flows — so the agent sees its own inventions in its vocabulary next
turn. That visibility is the whole point of deriving the prompt.

## The primitive boundary

Flows **compose** side effects; they cannot **create** new ones. The compiled
base is the power ceiling, so the base must be syscall-shaped: the side-effect
families (files, network, processes, time, state, config) as obligation-typed
events — "wide enough" answered per vocabulary, not universally.

New side effects = new compiled primitives = a platform act at a build
boundary. The rare mid-session need for a genuinely new primitive is a
**native module**: a compiled unit adding one primitive, descriptor validated
at mount, gated by the bridge — the kernel-module analog, as rare as a new
syscall. Flows are the common path; native modules are the exception.

## Invariants

- **Capability mutates, authority doesn't.** Defining a flow or mounting a
  module never widens the session's permission envelope; the define/mount gate
  is host-held and itself a register-declared capability.
- **Derived, never authored.** Grammar, prompt, enforcement, compiler all come
  from the register block.
- **Terminating.** The vocabulary bounds the compiler; unbounded vocabulary is
  a refusal, not a feature.
- **Prompt and enforcement are the same bytes.** The agent is told exactly what
  the interpreter will accept, because both come from the same declaration.

## Roadmap

- **R1 — the REPL define.** `run` discriminates declaration vs invocation;
  a defined-flows table in the session; definition-time obligation analysis and
  scope filtering. The interpreter-side change, at the `runtime.kz:1396`
  registry seam. This is the experiment: the agent defines a flow, sees it in
  its derived vocabulary, and dispatches it under the same possession rules.
- **R2 — grammar derivation.** A restricted wire grammar generated from the
  register block: the model can only express calls in the vocabulary, with no
  general-expression escape hatch. "Terminating" made syntactic.
- **R3 — the flow-compiler.** Defined flows lower to native handlers at
  definition time, bounded by the vocabulary. The summonable recompile.
- **R4 — native primitive modules.** The rare escape hatch for genuinely new
  side effects, gated and descriptor-validated.

## What this dissolves

- The "wide stdlib" question becomes per-vocabulary: a notes-agent needs its
  four verbs, a universal agent needs the six families, the runtime is the
  same either way.
- The dylib/sliver question is correctly scoped: loadable native units exist
  for **new primitives** (R4, rare), not for scopes or flows.
- The restart question: never. The bridge holding ambient resources across
  turns is the product; growth is live (define, mount), never by relaunch.
