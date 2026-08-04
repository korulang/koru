---
type: belief
id: frag-string-append-char-keystroke
provenance: session 2026-07-23 (Lars + Grok) — todo_tui rename; 610_022
ts: 2026-07-23
tags: [toolchain, string, tui, input]
---

# Keystrokes are bytes, not string literals

`std/string:append` takes a host `string` — fine for `" world"`, useless for
`k.ch` from a TUI key tor. Forcing a one-char `from-page` per keystroke is
a dodge that manufactures obligations just to feed append.

Ruling: `append-char` / `pop-char` are the keystroke surface (pin `610_022`).
Rename/draft buffers still move through take→mutate→insert today; in-place
mutation of a store-owned string is a later question, not a reason to skip
the byte API.
