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

## FIXED, same day — the belief now lives in code and this is the pointer

`\\` outside a string breaks the line exactly as `//` does
(`src/parser.zig`, in `extractProcBody`), and
`tests/regression/200_COMPILER_FEATURES/210_PARSER/210_202_multiline_string_is_not_proc_body_code`
pins all three shapes. `store.kz`'s `"};"` dodge is gone; the cell closes its
object in the format string like anything else, which is the proof the scanner
really changed. Full board after: **zero regressions**.

What is left here is only what the pin cannot hold.

**The loud failure was the lucky one.** The defect has two shapes and they differ
by nothing but nesting depth. At the top level the count goes NEGATIVE, and the
parser does report `PARSE004: unbalanced braces in proc body` — pointing at the
multiline string, naming no cause, but at least in the right file. One block
deeper the same fragment lands the depth on exactly ZERO, and **nothing is
reported at all**: the body is cut mid-`allocPrint`, its tail is emitted as
declarations of the enclosing module, and the first sign of trouble is `zig`
failing on a generated file. Which shape you get is decided by where you happened
to write the fragment. The instance that started this was the silent one.

**A survey found the blindness in one other scanner and it is unreachable.** Five
sibling brace scanners in `src/parser.zig` (the top-level `=`, `->`, `:` and head-
arrow finders, and the tor-shape reader) scan only Koru declaration and
invocation text, which never carries a `\\`. The inline-flow collector inside
`extractInlineFlows` genuinely does scan proc-body text and genuinely is blind —
and sits behind `if (false)` with a hard error in front of it. Fixing it would
have been speculative, so it was not fixed. Recorded because "we checked and left
one alone deliberately" is a different fact from "we checked and found nothing."

**The general shape survives the fix.** Same disease as
[[frag-a-host-line-local-degrades-tor-input-binding-to-textual-substitution]],
one stage earlier: a pass over source with no model of the language it is
reading. There the emitter substituted tokens inside string literals; here the
parser counted braces inside them. Both are cheap scanners standing where a lexer
belongs, and both failed by producing a wrong artifact rather than an error. The
scanner is one line better; it is still a scanner.

**Still unguarded, and it is the mirror worth building.** A proc whose body ends
early almost always leaves the enclosing module holding statements that are not
declarations. Nothing checks for that, so the NEXT way a body gets truncated will
be just as silent as this one was.
