---
type: belief
id: frag-vaxis-named-pump-attach
provenance: gallery routing + collector night 2026-07-24 — fuse sugar + tree-local page keys
ts: 2026-07-24
tags: [vaxis, pump, collectors, routing]
---

# Named pump attach is fuse sugar; page keys go tree-local under the route

`koru/vaxis:run(title)` owns the TTY loop (and `| err`). `koru/vaxis(name)` is
**not** a second pump and **not** a new scope — it is effect-only sugar that
splices more `! draw` / `! key` / `! tick` arms into the matching run's `__H`
(join key = run title, quotes stripped ↔ attach name). Attach sites may not
carry `|` terminals; orphan attach and multi-run-per-name fail loud.

Pump identity sits at the **same altitude as `std/store` names**: program-global
bare names. Not module-scoped. Qualify later only if composition forces it
(query rule ids are the different, per-module thing).

Signals stay real; meaning stays downstream of store state via routers
(`page-route = cond(page)` + `=>` named continuations — pin `320_137`). Under
`run`, bare `|` after `!` is a run terminal (KORU023), so page consumers
(`exhibit` / `on-key` / …) wrap the route — they do not hang off the pump's `|`.

**Tree-local keys (not flat cartesian guards):** once `page-route` has entered a
page, further key/state branching is a **local vocabulary** for that page
(`| clocks |> clocks-keys(ch)` where `clocks-keys = cond(ch) | c x when …`), not
a flat table of `| clocks when ch == … and ui.running == …` restating the page on
every arm. Collectors do not fix that ugliness; nested routers under the named
page do. Names stay global; the *tree* is continuation structure.

Probes: `koru-libs/examples/pump_attach*.k`. Live surface: `koru-examples/gallery/gallery.k`.
