---
type: belief
id: frag-a-type-word-prefix-must-match-a-final-segment
provenance: 440_008 — `DefinedFlows` mangled to `Defined__koru_ast.Flows` in emitted tor signatures; found while making the REPL-define boundary typed
ts: 2026-08-13
---

# A type-name rewrite must match whole identifier segments, never substrings (belief)

`writeFieldType` prefixed "AST types" (`Program`, `Item`, `Source`, `Flow`,
`Branch`, …) by a naive substring search-and-replace. Any user type whose name
merely CONTAINED an AST word was silently corrupted: `DefinedFlows` contains
"Flow", so every emitted tor signature spelled it `Defined__koru_ast.Flows` —
an undeclared-identifier error that surfaced only where the name was actually
used. The corruption was silent at compile time and loud at link time, in code
that never touched the ast module.

The fix: an AST word must be the FINAL identifier segment of the type name —
the whole bare name, the word after a pointer prefix (`*const Source`), or a
qualified segment (`ast.Flow`) — and the word list must name the full types
(`InvocationMeta`, not just its `Invocation` prefix). The rule is
segment-shaped because the legitimate cases are segment-shaped: qualified
names and pointer-prefixed bare names are the real forms, and a compound like
`DefinedFlows` is a different name entirely.

The general lesson: **a textual rewrite with a too-loose match corrupts names
it was never meant to touch** — the same failure shape as the store-shadowing
bug (690_271). Boundary-aware matching is the fix in both.

What would correct this: a structural type-resolution path that never
rewrites by text at all — the type is resolved to its module and spelled
from that, so substring accidents are impossible by construction.