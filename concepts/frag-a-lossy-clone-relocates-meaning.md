---
type: belief
id: frag-a-lossy-clone-relocates-meaning
provenance: introduced on main — fix(ast): a cloned path keeps its module qualifier
ts: 2026-08-01
---

# A clone that drops a field does not copy less — it copies something ELSE (belief)

A desugar that replicates a node is making a claim: *this arm means the same
thing at every place I put it.* That claim is only as good as the clone. Drop a
field and the copy is not a partial node — it is a **different, complete node**
that the rest of the compiler will happily resolve, check and emit, because
nothing downstream can tell a lost field from one that was never set.

The instance that made this a belief: `clonePath` copied a path's segments and
not its `module_qualifier`. A choke body calling across a module arrived, at
every replicated stage, as a call into the CURRENT module — same segments, new
meaning. It then misresolved against a nearby local name, and the diagnostic
named a tor that appears nowhere in the source. Nothing was corrupt; the
compiler was reasoning correctly about the wrong program.

**Why this class hides so well.** A missing field has no representation. There
is no null to trip an assert, no shape mismatch, no arity error — an optional
qualifier is *validly* absent for every local call, which is most calls. So the
lossy clone is indistinguishable from a legitimate node until something
downstream needs the dropped field, and by then the evidence of the drop is
gone. The error surfaces far from the clone and describes a program the author
never wrote, which is exactly the profile of a bug that survives a corpus.

**What a corpus does not protect here.** Field-dropping is invisible until a
clone site meets a node that USES the field, so coverage of the *transform* is
not coverage of the *clone*. A homogeneous ladder that re-raises `| failed`
never puts a cross-module call in a replicated arm, so the point-free tests, the
metacircular self-compile and a published post all passed over this for weeks.
The provoking shape came from outside the tree — see
[[frag-pointfree-threads-the-branch-left]] on why heterogeneous ladders are the
representative case, not the exotic one.

**The ruling.** A clone helper is exhaustive by default, and a field it declines
to copy is a decision that must be written down where the copy happens.
`cloneContinuations` already does this correctly for two — `kind` and
`plain_value` each carry a comment naming the bug that would follow from
dropping them, and `condition_expr` is nulled deliberately. That is the standard;
silent omission is not.

**Open questions.** (1) `cloneInvocation` still drops `variant`,
`return_binding`, `return_destructure`, `annotations`, `inline_body` and
`preamble_code`. Nothing in the corpus provokes them yet, and changing six
behaviours in a shared helper on speculation is its own risk — but each is the
same defect waiting for a shape. (2) The general form is worth a wall rather
than vigilance: a clone helper could be made structurally exhaustive so a field
added to the struct fails to compile until the clone decides about it. Zig can
express that; nobody has written it.
