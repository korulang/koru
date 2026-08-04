---
type: belief
id: frag-effect-unguarded-multicast
provenance: session 2026-07-23 (Lars + Grok) — KORU051 vs effect subscribe; todo_tui Dock wall
ts: 2026-07-23
tags: [effects, KORU051, multicast]
---

# Unguarded `!` handlers multicast; exclusive "else" is for `|` and when-chains

**Ruling (Lars):** multiple unguarded `! name` handlers are **subscribe-all** —
language-legal. KORU051 ("too many elses") applies to **exclusive** dispatch:
`|` outcomes, and `when`-guarded groups that need a single unguarded fallback.
A tor that refuses multicast rejects in **its own transform/emitter**, not
via the default flow checker inventing ambiguity.

## Why

`!` is a producer→handlers fire; linking the same effect twice is composition
(chrome + body both paint on `! draw`). `|` is a sum-type outcome — two
unguarded `| ok` arms are real ambiguity. Conflating them made KORU051 block
idiomatic vaxis scenes.

`branch_checker.firstDuplicateSibling` already held the kind split (effect
links may repeat; terminal at most one unguarded). Flow-checker KORU051 and
Handlers emission (first-unguarded-wins) had to catch up — pin `400_173`.

## Open edge

Resume-typed effects stay exclusive (one unguarded arm): multicast of resume
values has no coherent join. A tor may still teach-reject multicast in its
transform if its contract is single-handler; void `draw`/`tick` fire all.
