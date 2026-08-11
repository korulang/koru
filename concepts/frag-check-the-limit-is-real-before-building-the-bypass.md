---
type: belief
id: frag-check-the-limit-is-real-before-building-the-bypass
provenance: Lars, 2026-07-29, cutting through a parse-time pre-scan I had designed to route around koru.json
ts: 2026-07-29
---

# When a plan needs new machinery to sidestep an existing mechanism's limits, first check whether the limit is load-bearing (belief)

`std/vendor` needed `~std/vendor:bindings` to redirect imports at a granularity
koru.json's `paths` could not express — a key was read as the first path segment,
so `koru/vaxis` was unsayable and only "all of `koru/*`" could be said.

From that I designed a way around it: a frontend pre-scan of the entry file's AST
to build a redirect map before import resolution. It was well-motivated. Imports
really do resolve inline during the parse (`parser.zig:9866`) and transforms
really do run in Stage C, so a transform genuinely cannot feed resolution. Every
step of the argument was checked and correct.

The conclusion was still wrong, because the premise underneath it was never
checked at all: **that koru.json had to stay simple.** Nothing in the system says
that. It is our file. The granularity was an assumption I had inherited from what
the file happened to look like, and I built an architecture on top of it.

Lars's question — "could it be I'm attacking this from an old mindset where the
JSON file needs to be simple?" — dissolved the whole design. Make the existing
mechanism granular and the problem stops existing: no pre-scan, no source-order
hazard, and no new member of the "a pass runs before the thing it needs exists"
family. Pinned by `110_017_granular_path_longest_match`.

## The generalisable part

A bypass is *evidence of an unexamined premise*. The reasoning that justifies it
is usually sound — that is what makes it convincing — but soundness downstream of
an unchecked assumption produces confident, elaborate, wrong architecture. The
more carefully the bypass is argued, the more it deserves the question.

So the check runs one level up from where the work is happening: not "is my
workaround correct?" but "is the thing I am working around actually fixed?"
Cheapest form of it is to ask who owns the limit. A limit imposed by an external
format, a published protocol, or another team is real. A limit in a file we write
and read ourselves is a decision, and decisions can be re-taken.

## Why it recurs

The bias has a direction: modifying an existing shared mechanism feels risky and
broad, while adding a new parallel one feels contained. That intuition is often
backwards. Here, widening the resolver was a strict superset of its old behaviour
— every single-segment key kept its exact meaning, and all 94 1xx tests moved
zero — whereas the parallel pre-scan would have added a second resolution path,
a second place for the two to disagree, and an ordering hazard the codebase
already has three open red pins for.

Related: [[frag-a-transforms-filesystem-anchor-is-the-compilation-root]] — same
session, same shape. There too a step that survived careful checking was resting
on an unexamined assumption about where something lived.
