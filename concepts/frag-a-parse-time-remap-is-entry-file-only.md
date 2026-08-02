---
type: belief
id: frag-a-parse-time-remap-is-entry-file-only
provenance: 115_018, the store-insert mirror; the transform refused its own call site as "requires a store name" and the store name was sitting in the argument, under the wrong key
ts: 2026-08-02
---

# A parse-time pass that consults a registry cannot serve an imported module (belief)

The parser does a convenience for every call site: an argument that fills a
callee's implicit expression slot gets its key rewritten from the lexer's
speculative pun name to `expr`. To do that it has to know what the callee
declares — so it asks the event registry.

Inside an imported module, the registry does not have the answer yet. A module
is parsed BEFORE the import fold, so the callee's declaration is not registered
when the module's own call sites go through. The pass does not fail; it finds
nothing and leaves the argument alone. The site then carries `todos: todos`
where every downstream reader looks for `expr: todos`, and `std/store:insert`
refuses its own call site as *"requires a store name and a row block"* with the
store name sitting right there under the wrong key.

**This is structural, not a bug in that pass.** Any parse-time step that needs
to see a declaration from another file is entry-file-only by construction, and
it will be entry-file-only silently — the parse of a library simply happens at a
moment when the rest of the program does not exist yet. The question to ask of
any parser convenience is not "is it correct" but "what does it consult," and
anything beyond the current file's own text is the tell.

## The duplicate is not redundancy, it is the whole coverage

The same rewrite exists a second time in a post-fold pass, which sees both the
call site and the declaration. That copy is the one that works for modules —
and it was wired to flow HEADS only, so a mid-chain step in a library had no
working implementation at all. Neither copy was wrong about its own case; the
union of them just did not cover the grid.

Two implementations of one rule, each covering a different half, with nothing
naming the split: that is the shape
[[frag-frontend-checkers-see-one-file-not-the-program]] describes from the other
direction, where the "duplicate" turned out to be the only cross-module
enforcement there was. **Before collapsing two implementations of a rule, work
out which half of the grid each one actually covers.** The tidier one is
routinely the one that cannot reach.

## What it cost to see

The diagnostic named the author's source. Three separate walls fired that way in
one afternoon on this boundary — the parser's picker check, the store's
"unknown store", this one — and each was a correct refusal on an input the
machinery had already corrupted. On this boundary, a confident diagnostic
blaming the source is weak evidence about the source.

## Open

- Whether the parser's copy should simply be deleted now that the post-fold pass
  covers heads and steps. Two copies of a rule that differ in their tie-breaks
  (the parser skips an argument whose name matches a field; the post-fold pass
  takes the first unlabelled one) can disagree on a punned argument to a callee
  that also declares an expression slot. Nothing in the corpus writes that shape
  today, which is why the divergence has never been observed rather than why it
  is safe.
