---
type: belief
id: frag-store-cross-store-row-index
provenance: session 2026-07-23 (Lars + Grok) — todo_tui space/x; 690_075 690_076
ts: 2026-07-23
tags: [toolchain, store, addressing, lowering]
---

# Dotted bracket heads are not always self-FK

`store[expr].field` has two dotted-index meanings:

1. **Self-FK hop** — `nodes[a.next]`: `next` is a handle-carrying column of
   *this* store; the head follows that column (one hop). Pin `690_048`.
2. **Foreign cell as row index** — `todos[ui.sel]`: `sel` is *not* a field of
   `todos`; `ui.sel` is another store's cell. That must lower to
   `__koru_store_ui.sel` as the row argument — not error as a failed self-FK.
   Pin `690_075`. The same rewrite belongs on `take(store[…])`.

A third, related lower: an indexed field **read** in a stored RHS
(`1 - todos[ui.sel].done`) is not `store.cell` (no dotted store name before
`[`); it must become the SoA column form. Pin `690_076`.

`std.store` sites skip the create-time whole-program Walk for their args
(transforms own rewriting) — so these lowers live in `stored`/`take`, not
only in create's Walk.
