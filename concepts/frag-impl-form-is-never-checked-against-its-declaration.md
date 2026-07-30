---
type: belief
id: frag-impl-form-is-never-checked-against-its-declaration
provenance: Lars changed `->` to `=>` on one line of koru-examples/human-doodle/doodle.k, 2026-07-30; pinned red as 510_112/113/114
ts: 2026-07-30
---

# An implementation's form is never checked against the declaration it implements (belief)

A `tor` declares its output shape — a bare return (`-> T`) or named branches
(`| ok` / `| err`). Its implementation then commits to a form: `->` for a bare
return, `=> <branch> <value>` for a branch constructor. Nothing verifies that the
form matches the declaration, or that a named branch exists. The disagreement is
discovered by **Zig**, against types Zig synthesised, and reported against
`output_emitted.zig` — a file the author never opened.

Three spellings of one missing wall, all reproduced 2026-07-30:

- **bare-return decl, `=>` impl** — `type '[]const u8' does not support struct
  initialization syntax` (`510_112`, Lars's doodle)
- **branch decl, `->` impl** — `expected type '…get_input_event.Output', found
  '*const [2:0]u8'` (`510_113`)
- **impl names an undeclared branch** — `no field named 'nope' in union
  '…get_input_event.Output'` (`510_114`)

## The information is all present, in the same file, at parse time

`--ast-json` on the doodle shows the impl node as
`{ branch_name: "response", fields: [], plain_value: null }` — `response` was read
as a *branch name* with an empty payload — against an `event_decl` carrying
`branches: []`. `ast.zig:1544` documents the pairing in so many words: the
bare-return impl's "branch_name is empty; plain_value is the expression … Pairs
with `EventDecl.return_type`." A `=>` impl naming a branch on a tor declaring zero
branches is decidable from those two fields. The third case is a set-membership
test over `EventDecl.branches`.

This is **not** the one-file-visibility limit of
[[frag-frontend-checkers-see-one-file-not-the-program]]. Declaration and
implementation are adjacent lines of one file. The checker has both.

## The compiler already owns the vocabulary it declines to use

Two existing diagnostics prove the taxonomy is understood:

- `PARSE003` rejects the **declaration**-side version of exactly this confusion —
  a single payload-carrying branch — and teaches the fix: "declare the single
  output as a bare return instead: `-> <type>`" (`parser.zig:2322`). The
  implementation-side mirror has no wall.
- `KORU047` enumerates all four implementation forms by name when an event has
  none: proc, bare-return `-> <value>`, branch constructor `=> <branch> <value>`,
  subflow. It can already say which form is which, in prose, to the author.

So the gap is not conceptual and not a missing notion. It is a check nobody wrote,
in a position where the backend's own type system happens to catch the error and
therefore nothing looked broken.

## Why this class hides

A backend error is still *an* error, so these programs do not silently
misbehave — the build fails. That is what kept it comfortable. But the failure is
unreadable to the person who caused it: it names a generated file, a synthesised
union, and a Zig syntax rule, and never names `=>`, `->`, or the tor. Compare
`510_090`, which also rejects at backend stage but says "unknown label
'@missing'" — koru's own words about the author's own text. A backend-stage error
can still be a koru diagnostic; these are not.

The pins therefore assert `FRONTEND_COMPILE_ERROR` plus
`NOT_CONTAINS output_emitted.zig`, and deliberately invent no diagnostic wording.
The claim is only: this must be rejected before emission, and the message must not
name a file the author never wrote. See
[[frag-a-diagnostic-that-names-a-line-must-translate-it]].

## Open

Where the wall belongs — the parser (which already hosts `PARSE003` and sees both
nodes) or a frontend checker (which is where a set-membership test over declared
branches more naturally lives, and which would also cover impls arriving from a
subflow rather than an immediate literal). That choice is Lars's, not mine; the
pins constrain the behaviour and not the site.

Also open: whether the arity of a branch constructor is a fourth case or the same
one. `=> response` supplies a branch name and no value, which contradicts the
`=> <branch> <value>` shape `KORU047` teaches, independently of the decl
mismatch. `510_112` currently pins both grounds at once because one line
exhibits both.
