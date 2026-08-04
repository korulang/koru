---
type: belief
id: frag-markup-tags-kebab
provenance: session 2026-07-23 (Lars + Grok) — casing itch after Dock/StackPanel
ts: 2026-07-23
tags: [toolchain, vaxis, markup, naming]
---

# Markup tags are lowercase kebab — same rule as tor names

`<text>` was lowercase; `<Dock>` / `<StackPanel>` were Pascal. That mix was
accidental dialect, not a thesis. Koru markup tags match the names they
stand for — the XAML rule — spelled the koru way: lowercase kebab like
tors and `component(todo-row)` → `<todo-row/>`.

Law: `<text>`, `<dock>`, `<stack-panel>`, user components as declared.
Pascal layout tags are dead; they resolve as missing components and fail
loud. Mimicking foreign casing for "visual distinction" loses when the
DSL already has one naming law.
