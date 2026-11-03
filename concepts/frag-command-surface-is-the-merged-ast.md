---
type: belief
id: frag-command-surface-is-the-merged-ast
provenance: quench seat w1C:p5A 2026-11-03 — `koruc <file> help` printed
  "No commands defined" while `install` from std/package dispatched on the
  same file; `explain` refused though declared in std/explain
ts: 2026-11-03
---

# The command surface is the merged AST — enumeration must read what dispatch reads (belief)

`help` enumerated the pre-merge entry AST while dispatch resolved post-merge:
imported `[comptime|command]` events were invisible to the listing, so the
tool printed a surface that was not the real one (310_148). Same shape as
`explain` refusing: the command existed in `std/explain` but nothing gated it
in — now the bootstrap declares `~[command(explain) or command(help)]import
std/explain`, the `command=` provider atom carrying it on every program
without a user-side import (310_146). A listing, a refusal, or a dispatch
decision that reads a different AST than the resolver is a false report
about the tool's own verbs.
