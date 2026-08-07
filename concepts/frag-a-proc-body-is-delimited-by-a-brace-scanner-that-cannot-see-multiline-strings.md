---
type: belief
id: frag-a-proc-body-is-delimited-by-a-brace-scanner-that-cannot-see-multiline-strings
provenance: store.kz's JS container cell — a `\\`-string ending `}};` silently truncated the `new` transform and spilled its remainder into the koru_std namespace, surfacing as a Zig syntax error 5,700 lines into a generated file
ts: 2026-08-07
---

# A `~proc` body ends where a hand-rolled brace scanner says it does, and that scanner reads Zig multiline strings as code (belief)

`extractProcBody` (`src/parser.zig:3725`) finds a proc's closing brace by counting
`{` and `}` across lines. It is careful about two things and blind to a third:

- `//` to end of line — skipped.
- `"…"` and `'…'`, with backslash escapes — skipped.
- `\\…` — **not skipped.** A backslash increments an escape counter, so `\\` is
  read as one escaped backslash, `escape_count` lands even, and everything after
  it on the line is counted as ordinary code.

So every brace inside a Zig multiline string literal moves the depth. In a
`std.fmt` format string a literal brace is written `{{`, which counts as **two**.
A fragment that is perfectly balanced *in the text it emits* can be unbalanced *in
the source that writes it*, and the two counts are not related by anything an
author would think to check.

## Why this costs an hour rather than a minute

The failure is silent, and it is reported in the wrong file, at the wrong stage,
about the wrong thing.

When the depth reaches zero early, the parser simply believes the proc ended
there. Everything after that point stops being a proc body and becomes
declarations of the enclosing module — so a `var appended_items = …;` from the
middle of a transform is emitted at container scope in the generated backend.
Zig then reports `expected ',' after field` at line 5,706 of
`backend_output_emitted.zig`, a file nobody wrote, thousands of lines from the
`.kz` line that is actually wrong. Nothing anywhere names braces, or strings, or
the proc that got cut in half.

The corpus has been keeping this invariant by accident. `store.kz`'s existing
`\\`-string blocks are all brace-balanced in source, including their `{{`/`}}`
pairs, because their emitted Zig happens to be balanced too — which is true for
code and false for a fragment that opens its brace in one string literal and
closes it in another. The JS cell did exactly that: `" = {\n"` (a real string, so
the `{` is skipped) opened the object and `\\}};` (a multiline string, so both
braces are counted) closed it. Net minus two.

## What follows

- **The fix is one line in the scanner and it has not been made.** `\\` outside a
  string should `break` the line exactly as `//` does. `src/parser.zig` is
  ask-first by `AGENTS.md`, so this is written down rather than done. Until then
  the rule a `.kz` author has to hold in their head is: *a proc body must be
  brace-balanced as raw source text, counting `{{` as two.*
- **A workaround exists and should not be mistaken for the fix.** Appending a
  closing brace as a plain `"};"` string keeps the source balanced, because plain
  strings ARE skipped. That is what `store.kz` does now, with a comment saying
  why. It is a local dodge around a scanner defect, not a design.
- Same disease as
  [[frag-a-host-line-local-degrades-tor-input-binding-to-textual-substitution]],
  one stage earlier: a pass over source with no model of the language it is
  reading. There the emitter substituted tokens inside string literals; here the
  parser counts braces inside them. Both are cheap scanners standing where a
  lexer belongs, and both fail by producing a wrong artifact rather than an
  error.
- **What would make this loud without fixing the scanner:** a proc whose body
  ended early almost always leaves the enclosing module holding statements that
  are not declarations. Nothing checks for that today.
