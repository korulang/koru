---
type: belief
id: frag-comptime-obligation-discipline
provenance: introduced by e9025dba — test(comptime): pin 310_102 RED — comptime obligations checked-but-too-late
ts: 2026-07-06
---

# Comptime obligation discipline — checked-but-too-late (pipeline belief)

Koru's obligation checking covers **two executions** of Koru code: the
runtime program and the comptime program. The runtime half shipped long
ago (analysis: `check-structure → pass-auto-discharge → check-flow →
check-phantom-semantic → check-purity`, compiler.kz:839). The comptime
half was believed absent — `comptime_eval.zig` carries zero phantom or
obligation machinery. Pin 310_102 (2026-07-06) corrected that belief:
the analysis pass DOES see `[comptime]`-marked flows that survive into
the AST and DOES reject their leaks (KORU030). **The gap is ordering,
not absence**: all comptime machinery runs in the frontend
(`process-template-procs → fold-comptime → evaluate-comptime`,
compiler.kz:828) — so a leaking comptime flow *executes first* and is
rejected *after*. Observed: a tainted sink printed at compile time,
twice (fold and evaluate both walk the flow), before the build failed.
Comptime side effects precede their own rejection.

Ruled fix (Lars, 2026-07-06): invoke the **same** phantom checker as a
frontend segment scoped to `[comptime]`-marked items, positioned BEFORE
`process-template-procs`, with a comptime-scoped auto-discharge run
ahead of it (mirroring the analysis-side ordering, compiler.kz:1402).
One implementation of obligation semantics, two invocation points, two
executions disciplined — no drift possible between comptime and runtime
obligation rules, and no comptime side effect can precede its own
rejection. Prerequisites verified: canonicalization happens in Stage A
(main.zig:6889), so the checker's path requirements hold at any Stage-C
position; the pipeline segments are user-overridable flows, so the
insertion is an ordinary chain edit.

Why it matters now: the type-system design (registry + providers) makes
comptime code the most resource-active code in the language — providers
doing IO at comptime (`<file!>`, sockets fetching schemas) and
type-construction obligations whose whole lifecycle is comptime
(`<schema!>` … seal). The three-tier honesty ladder: (1) runtime Koru —
statically checked in analysis, shipped; (2) comptime Koru — statically
checked in frontend, pinned red at 310_102; (3) raw-Zig proc/template
bodies — the deliberate escape hatch, unchecked by design.

Open observations riding the pin: double evaluation of comptime flows
(fold + evaluate), and the leak diagnostic pointing at
`auto_discharge:33:0` instead of the user's source, naming nothing
about the comptime context.
