---
type: belief
id: frag-a-file-source-closure-is-step-level
provenance: 100_089 pin investigation 2026-11-15 — `@"path"` inside call
  parens misfired the file-source marker scan (an unbalanced-parens lie)
  and, as a `.kz` host line, rode into backend Zig as an escaped identifier
ts: 2026-11-15
tags: [koru, parser, file-source, grammar]
---

# A file-source closure is step-level only — `@"` inside parens is not a marker

`@"path"` (and the removed `<type>"path"` echo) is the file twin of the
inline `{` source block: it attaches to a STEP — `render.file @"hello.txt"`,
`|> fmt.blk @"banner.txt": f` — where the parser reads the file at compile
time and fills the parameter's `Source` implicitly. It is not an argument
value and never was: inside `(...)` the bare text survived arg splitting
and emitted as a Zig escaped-identifier token, dying in backend Zig with a
nonsense error — the hole that let `std/guide:add(key) @"guides/x.md"}`
ride into `bench/airline_guides.k` as include-ref prose.

Two scans guard the position, and both must be structural, not textual:

- `findFileSourceMarker` decides "is there a closure on this step line" —
  it must skip `@"`/`>"` inside `(...)` and `{...}`, or it rips `f(` off
  its `)` and the line dies as "unbalanced parentheses": a refusal that
  lies about the cause.
- `lexer.parseArgs` refuses a bare `@"` outside strings, `{...}` host
  blocks, and comments — the single choke point for parser.zig's three
  arg sites and flow_parser's two, so the interpreter surface refuses the
  same shape.

The refusal is Koru-surface only. In a `.kz` host line `@"..."` is a
legal Zig escaped identifier and must not be refused — which is why the
pin's payload needed `~` to reach the grammar at all.

Open question: `@"` inside `[...]` at step level is untracked — no corpus
shape produces it; if one appears the marker still fires textually.
