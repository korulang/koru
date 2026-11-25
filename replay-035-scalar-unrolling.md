# Replay artifact — challenge 035 cell: bounded scalar recursive unrolling

**Frame:** `035_the_proof_carrying_machine` — evaluation-strategy lowerings;
coverage grows by discharging proofs, never by weakening checks.
**Leg:** recursion war leg 1 of 3, worktree `/tmp/recwar-1`, branch
`recwar/unrolling`.
**Cell landed:** *peeling* — bounded depth-unrolling of proven scalar
self-recursion, emitted as a dedicated machine through the existing
`flow.inline_body` lowering (zero emitter changes).

## What the pass is

`src/recursion_unroll.zig` (~470 lines), wired as `unroll-recursion()` in
`koru_std/compiler.kz` elaborate, positioned after `run-pre-transforms()`
and **before** `process-template-procs()` — the last point where `if` is
still a structured invocation with a continuation tree rather than Zig
`inline_body` text.

Mechanism: for each impl flow whose tor passes the predicate, the pass
alpha-renames the body's bind set (`__u<N>_*` — Zig forbids shadowing),
substitutes parameter→argument-expression envs, and writes the unrolled
machine as Zig text into `flow.inline_body`. `emitFlow` →
`emitInlineBodyNode` lowers it verbatim; marker-free text needs no
continuation resolution. Residual self-calls at the depth boundary emit
`main_module.<ev>_event.handler(.{ ... })` — recursion is always
preserved.

## The proof it carries (predicate = the witness)

An impl flow transforms only when ALL hold:

- **Tor shape:** `-> int` return, all-int-scalar inputs, no named/effect
  branches, no phantom, single-segment path in the entry module (emits as
  `main_module.<seg>_event`).
- **Body allowlist:** only `std.control:if` dispatch invocations, self-call
  invocations with named return bindings, `.expression`/bare-return
  produce leaves. No conditions, continuation bindings, destructures,
  assignments, inline code, labels, foreign calls — the allowed node set
  is pure scalar arithmetic **by construction** (least-strict gate per
  the effect-set ruling: substitution preserves evaluation order and
  effect count exactly, so no EffectSet is needed for v1).
- **Termination witness:** one input param decreases by a positive int
  constant on EVERY self-call site (`param - <digits>`); other params
  unconstrained (hanoi's `acc`, pascal's `k`).
- **Nested-call refusal:** a self-call whose arg mentions an earlier
  self-call's bind (hanoi's `acc: h + 1`) is the flat-segment machine's
  class — it lowers natively and would ignore `inline_body`; the pass
  refuses rather than claim a dead transform.
- **Growth cap:** G(D) = (s^(D+1)−1)/(s−1) body copies ≤ 64; D=2 default,
  hard cap 3. `KORU_UNROLL_OFF=1` disables; `KORU_UNROLL_DEBUG=1` logs
  every accept/reject reason.

## Coverage map (this cell)

| Class | Verdict | Witness |
|---|---|---|
| fib (sibling self-calls, `a+b` produce) | **LOWERS** depth 2 | decreasing `n`, pure scalar body |
| pascal/binoim (nested `if` + sibling calls) | **LOWERS** depth 2 | decreasing `n`; `k` unconstrained |
| hanoi (nested-call arg `acc: h+1`) | stays native — **seg machine** | `flowIsFlatEligible` → `__koru_seg` `@call(.always_tail)` chain; per t6z the trampoline IS the win (+18% worse native) |
| coins/tak/ackermann/mutual | stays native | no common decreasing param / mutual / effectful shapes — predicate refuses by name |
| effectful/obligation tors | stays native | foreign invocations, conditions, bindings all refuse |

## Measurements

- **Correctness (oracle-green):** fib(35) → `9227465` ✓; hanoi(25,0) →
  `33554431` ✓ (seg path unchanged); pascal C(27,13) → `20058300` ✓.
- **fib(35) wall, this machine:** see `hc` report for the ON/OFF
  ReleaseFast A/B (`KORU_UNROLL_OFF=1` is the like-for-like baseline).
- **Spike calibration** (`/tmp/recwar-spike.md`): honest unrolled-vs-rec
  under forced indirect calls ≈ **1.9×** (14.0ms vs 26.3ms); the earlier
  257×/0.00ms numbers were gcc -O2 CSE collapsing duplicate call sites —
  measured, not assumed. LLVM terrain is already parity/won pre-pass
  (hanoi 0.78× vs clang); the war target per t6z is **recurrence-collapse**
  (gcc rewrites `acc+1` chains toward `acc+2^n−1` closed form) — that is
  leg 2/3 scope, not peeling.

## Front-3 finding (compile-time eval)

`src/comptime_eval.zig` exists (Evaluator/Value/Env) and `fold-comptime`
runs in elaborate — but koruc emits **naive runtime handler calls for
literal inputs today** (`const r = main_module.fib_event.handler(.{ .n =
35 });`). No compile-time evaluation of the recursive tor chain exists.
Per the latest arbiter input, comptime-eval v1 needs no effect-set —
closed-world resolution + hygiene IS the proof. Front 3 is a **build**,
not a wire-up; it is the cell where competitors structurally cannot
follow.

## Known limits / next legs

- Single-segment entry-module tors only; imported-module recursion
  refuses (emitted module name differs).
- `if`-only dispatch; `cond`/match shapes refuse.
- Bind names must be unique per body (duplicate `return_binding`s would
  collide — loud Zig error, not silent wrong-code).
- Expression leaves are text-substituted; parsed-expression validation is
  the widening path (expression_parser exists).
- Leg 2 candidates per the frame's dependency order: recurrence-collapse
  recognition (accumulator structure visible in AST — the t6z ceiling),
  comptime-eval of literal-input pure recursion, D as a measured knob
  (backend survival at D=9 unmeasured per /tmp/peelwar-costmodel.md).
