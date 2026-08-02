---
type: belief
id: frag-resolution-anchors-on-the-flows-home-module
provenance: fixing 115_012, the parser mirror; the grammar lookup was the visible fault and the wrong anchor was underneath it, invisible until the lookup was fixed
ts: 2026-08-02
---

# A name resolves against the module it was WRITTEN in, never against the program's main module (belief)

Two faults sat on top of each other in `[with]` vocabulary resolution, and the
second only became visible once the first was gone. That stacking is the durable
part; the pass is the occasion.

The first is the one the 115 wall was built to find: a walk over
`program.items` that never descends through `.module_decl`, so the pass simply
does not visit a flow that lives in a library. Known class, gardened already,
and cheap to fix once seen.

The second is the interesting one. The pass asked *"is this name stamped with
the main module?"* as its test for "is this an unqualified name I am allowed to
restamp." In the entry file that question is correct by accident — the file's
derived name, the import-derived logical name and `main_module` all collapse
into one word. In a library it is simply the wrong question, and it fails
CLOSED: every bare name in a library flow reads as *already qualified, not
mine*, and the pass declines to touch it while walking straight over it.

**The anchor for "unqualified here" is the flow's HOME module.** Canonicalize
stamps a bare name with the module it was written in; the resolver has to ask
against that same module or it is comparing two different domains. `main_module`
is not a synonym for "here" — it is only ever "here" for one file in the
program.

## Why this is worth writing down rather than just fixing

A descent fix looks complete when the walk reaches the node. It is not complete
until every value the walk *carries down* is re-derived at the new depth. A
walk that descends but keeps passing the top-level's notion of "here" has
traded a silent skip for a silent no-op, which is strictly harder to see: the
pass now runs, reports nothing, and changes nothing.

So the check on any descent fix is not "does it visit the node" but "what did
this function believe about its position, and is that belief still true one
level down." Here the belief was one string parameter.

## The fault shape it produces downstream

Neither fault reported itself. The diagnostic the author actually read was
`std/parser:parse` refusing the grammar's own picker as "not the static
`std/parser:match(<cursor>)` shape" — a wall firing correctly on a path it was
handed unresolved. A refusal three layers from the fault, phrased with total
confidence, and blaming the author's source.

That is the second time this area has produced a diagnostic that names the
author's code for a fault in the machinery
([[frag-transform-module-exposure-is-not-one-fault]] carries the first). It is
worth suspecting the phrasing of any wall that fires only when the subject
moves into a module.

## Open

- Whether other passes carry `main_module_name` as a stand-in for "here". The
  name is load-bearing in the emitter's qualifier logic too, where it means
  something legitimately different (which module's namespace to emit INTO), and
  the two meanings are one identifier apart.
- Whether "home module" wants to be a field on the flow rather than a parameter
  threaded through every walk. A parameter is one refactor from being wrong
  again; the flow already knows the file it came from.
