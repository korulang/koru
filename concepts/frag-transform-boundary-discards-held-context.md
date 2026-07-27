---
type: belief
id: frag-transform-boundary-discards-held-context
provenance: surfaced while designing the Koru type registry's comptime surface, 2026-07-27; the seam was found looking for somewhere to put `site.err`
ts: 2026-07-27
---

# The transform boundary discards a context it is holding — the missing error channel is a seam at one call, not a structural absence (belief)

The compiler has said, in its own source, that comptime transforms have nowhere
to report an error. `koru_std/compiler.kz` states it at the point of the
workaround — the pipeline calls `std.process.exit(1)` rather than leak an
ICE-shaped panic, "since `evaluate-comptime`/`run-pre-transforms` return a ctx
with no error channel" — and [[frag-transform-continuation-position]] repeats it
as the justification for how KORU124 stops the pipeline.

Read as an absence, that claim licenses a whole family of workarounds: bare
panics, `@compileError`, `std.debug.panic` from inside a library reaching the
user. The comptime surface audit counted twenty-one copy-pasted panics living
under it.

**It is not an absence.** `run-pre-transforms` declares `{ ctx: CompilerContext }`
and is holding that context — with its `errors`, `warnings`, `error_policy` and
the `original_ast` reserved for metadata queries — at the moment it exits. What
is missing is the context's *reach*: the runner calls `run_pass` with `ctx.ast`
and `ctx.allocator`, decomposing the context into the two fields transforms
happen to need, one frame before the transforms that need the rest. Everything
downstream — the pass runner, the handler table, the emitted handler input —
inherits that narrowed signature and cannot recover what was dropped above it.

So the correct sentence is not "there is no error channel" but "the channel
stops one frame short." That distinction decides what gets built: an absence
invites a substitute, a seam invites widening.

## Why this matters beyond the one call

A transform that can only panic can only fail in the host's voice. Every
guarantee Koru wants to grow in userspace — a library rejecting a bad type, a
generic refusing an argument it cannot handle — needs the author to be able to
say no *in Koru's voice*, with a location and a code. That capability was
reachable the entire time; nobody widened the seam because the comment said
there was nothing there.

The general shape is worth carrying: **a documented absence in a codebase is a
claim, and claims decay.** When a comment explains why something cannot be done,
check whether the thing it says is missing is being held one frame up. The cost
of not checking is not a missing feature, it is a family of workarounds that
each look locally reasonable.

Related: [[frag-transform-continuation-position]] (carries the prior claim, in
service of a different and still-correct belief about the whole-program escape),
[[frag-a-red-pins-assertion-goes-unexamined]] (same failure mode one layer up — a
claim survives because its verdict explains itself and nobody reads the claim),
[[frag-type-system-design]] (the arc this was found under).
