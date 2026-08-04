---
type: belief
id: frag-dock-stackpanel-fill
provenance: session 2026-07-23 (Lars + Grok) — todo_tui chrome+list markup tree; kebab evolve
ts: 2026-07-23
tags: [toolchain, vaxis, layout, dock, stackpanel]
---

# `stack-panel` inside `dock` is a nested layout, not a component name

Dock's fill slot used to treat every inner tag as a child *component*. Nested
`<stack-panel dock="fill">` must not look up a component tor — it is a
**layout container**: dock carves the fill window, then stack-panel owns y
inside it. (Markup tags are lowercase kebab — `frag-markup-tags-kebab`.)

Two fill shapes:

1. **Static kids** — flatten into the fill (`sub` + child invoke), same thesis
   as top-level stack-panel.
2. **Empty** — live fill: init a `stack` cursor over the fill window and
   **return** that `Stack` from the component so draw-time `sweep` →
   `stack-row` can push rows. Chrome + list stay one markup tree; live
   children stay a draw-time concern.
