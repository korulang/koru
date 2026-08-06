---
type: belief
id: frag-a-transform-renders-two-languages-from-one-body
provenance: kernel JS port — 1391 lines, ~60 emission sites, eight of them actually differ between targets
ts: 2026-08-06
---

# A `|js` variant is for two programs, not for one program with a few seams

The JS-target plan reads as though porting a transform always means writing a
`|js` rendering beside the `|zig` one. For `regex` that was right: `match` and
`scan` assemble genuinely different dispatch — a Zig `if (fn(x)) |sp|` ladder
against a JS `let`-hoisted chain — and the two bodies want to be read side by
side.

For `kernel` it would have been a mistake. `init` is 1391 lines. Roughly sixty
are emission sites, and **eight of them differ between targets**: the array
literal, three loop headers, the pointer binding, the field separator, the branch
return, and how the static declaration reaches the file. Everything else — the
shape lookup, the op collection, the plan validation, the binding rewrite that
turns `k.other.x` into `ptr[j].x` — is target-agnostic, because it manipulates
the AST rather than emitting text.

A `|js` variant here would have been 1391 lines of copy in which eight lines
differ, and the next person to fix a kernel bug would fix it once.

`~capture` had already settled this, and said why in the source
(`control.kz:427`): read the build language ONCE and let both spellings fall out
of it, because a second field would be *"two lowerings of one construct."* The
same judgment applies to a whole transform body, not just to one field.

**The test is not the size of the transform — it is how much of its OUTPUT
differs.** Ask what fraction of the emitted text changes with the target. Mostly
different (a dispatch ladder, a splice protocol) → variant. Mostly shared with a
handful of seams (loop headers, literal syntax) → one body branching on
`CompilerEnv.lang`. Getting this backwards costs either a duplicated body that
drifts, or a tangle of conditionals inside a transform that should have been two.

A corollary about what "host-agnostic" actually covers: the kernel op bodies are
portable because `ptr[i].mass *= 2.0` is the same text in both languages. That
holds for arithmetic and stops at Zig builtins — one fixture writes `@sqrt` into
an op body and has no JS lowering. Portable-looking user text is portable only as
far as the operators it uses.
