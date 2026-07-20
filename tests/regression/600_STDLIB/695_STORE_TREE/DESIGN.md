# `[tree]` store — design spec (draft, 2026-07-20)

A comptime lens that declares a flat store to be a tree/forest, reusing the
store's existing T2 (cycle rejection) and T3 (maintained aggregates) machinery.
NOT a second storage kind — storage truth stays flat rows + a foreign-key parent.

## Ruled with Lars (2026-07-20)
- **Forest.** Multiple roots; `parent == null` is a root. A single composition
  root is expressible on top, never required.
- **Auto-synthesized parent.** `[tree]` synthesizes the canonical `parent` field;
  user rows do not declare it. (Escape to an explicitly-named parent field is a
  future option, not v1.)
- **Aggregates opt-in.** Nothing is maintained by default. depth / subtree_size /
  path-to-root materialize a column ONLY if a query or watch reads it (T4:
  "layout is the closure of the queries").
- **Maintained layout is optional, never mandated.** The store is built for
  performance; naive path-sum layout won't be sophisticated enough for every
  case. A `[tree]` store gives *structure* + *optionally-maintained simple
  aggregates*; a sophisticated layout engine may consume the tree and compute
  layout its own way, bypassing the maintained path entirely.

## Shape
```
[tree]std/store:new(widget-tree) {
    // user fields only — parent is synthesized
    x: 0[i16], y: 0[i16], text: ""[string]
}
```
`[tree]` adds, at comptime:
1. **Parent pointer** — synthesized `parent: ?<row-id>` (null = root).
2. **Invariants (reuse T2)** — single parent by construction; acyclic enforced at
   the write site (reparent that makes a node its own ancestor → rejected, same
   machine as cascade-cycle rejection).
3. **Opt-in maintained aggregates (reuse T3)** — depth, subtree_size,
   path-to-root; each compiles to delta updates at write sites, materialized only
   when read.
4. **Algorithm surface** — traversals (pre/post/DFS/BFS), ancestors, descendants,
   subtree, reparent, remove-subtree, roots (forest entry points).

## Theses — attack these

- **TT0 · FOUNDATION (prerequisite, likely NOT yet built) — a store field can
  hold a row handle referencing another row in the SAME store (self-FK).**
  Grounded finding (2026-07-20): handles today are used ONLY for *indexed
  addressing* — `std/store:take(pool[r])`, `store[handle]` (690_016/022/023/024/
  029/033/034/036). NO passing test stores a handle *as a field value* referencing
  another row. So `stored { node.parent: r }` — the entire premise of the parent
  pointer — is DESIGN INTENT (ruling 9 "foreign keys — rows reference rows"; T6
  "insert returns a row handle"; DESIGN.md:56 "660_027 substrate for store handles
  carrying …") but UNVERIFIED in the implementation. This is the first red to pin
  and the real first build step. Everything below (parent synthesis, cycle
  rejection, aggregates, traversal) sits on it. TT0 must prove:
    - a field can be typed as a handle to a row of the same store,
    - `stored { node.parent: r }` sets it (r from `insert … | row r`),
    - it round-trips: reading `node.parent` yields an addressable handle
      (`store[node.parent]`), null before set,
    - it is queryable (`query … entity.parent`) so traversal can follow it.
  If TT0 is genuinely not there, `[tree]` reduces to: *build self-FK first, then
  the tree lens is thin.* Do NOT let `[tree]` route around a missing self-FK by
  hiding a parallel index — fix the store substrate.

- **TT1 · Parent synthesis is invisible.** The row shape the user writes has no
  parent field; the canonical `parent` is added by the annotation and is the only
  name the algorithms reference. Writing a node with no parent = a root.
- **TT2 · Acyclicity is a write-site rejection, not a runtime check.** `reparent(n,
  p)` where `p` is in `subtree(n)` is rejected with a koru diagnostic naming the
  cycle. Reuses T2's comptime-visible write-graph cycle rejection.
- **TT3 · Unread aggregate materializes NO column.** If nothing reads `depth`,
  there is no depth column and no per-write depth maintenance (T4 closure).
  Reading `depth` in one watch turns on its delta-maintenance everywhere it's
  written — and only then.
- **TT4 · reparent is O(1) + bounded delta.** Pointer swap is O(1); the only extra
  work is delta-propagating the *maintained* aggregates over n's subtree. No
  maintained aggregates → pure pointer swap, zero traversal.
- **TT5 · Forest.** Multiple roots are legal; `roots()` enumerates them;
  algorithms operate per-root or across the forest. No implicit super-root.
- **TT6 · (windows) layout-as-aggregate is opt-in and escapable.** Absolute
  `(x,y)` = path-to-root sum of relative offsets, available as a maintained
  aggregate — but a consumer may ignore it and compute layout itself over the raw
  tree. The tree store does not own layout.

## Open (decide before / while attacking)
- **Child ordering.** Windows need sibling order (z / paint order). Is the tree
  ordered? Likely yes → a synthesized `sibling_order` or an explicit order field.
  (Deferred; pin the unordered core first.)
- **Removal semantics.** `remove-subtree` cascades (T2 cascade delete) vs
  reparent-orphans-to-root. Lean: cascade, with reparent as the explicit
  alternative.
- **Escape-hatch shape.** How a sophisticated layout engine opts OUT of maintained
  layout while still using the tree structure + traversals.

## First acceptance pins (the honest reds to write before code)
0. **Self-FK substrate (TT0).** A plain store (no `[tree]` yet): a field holds a
   handle to another row of the same store; `stored { node.parent: r }` sets it,
   `store[node.parent]` addresses it, `query` reads it, null before set. This is
   the foundation — pin it first, prove it, THEN layer the tree.
1. `[tree]` store, insert nodes with parents, `preorder` traversal → deterministic
   output. (TT1, TT5)
2. `reparent` moves a subtree; a *read* `depth` aggregate reflects the new depth.
   (TT3, TT4)
3. Cycle attempt (`reparent` into own subtree) → clean koru rejection. (TT2)
4. Forest: two roots, `roots()` returns both; per-root traversal. (TT5)

## Build order for Fable
TT0 first (self-FK is the substrate everything needs). Only once a handle
round-trips as a field value do TT1–TT6 become a thin lens. If TT0 is a bigger
lift than expected, that IS the finding — the tree is downstream of it.

## Where it lives (proposal)
- Feature-unit tests: a new store subcluster, e.g.
  `tests/regression/600_STDLIB/695_STORE_TREE/` (this doc becomes its DESIGN.md).
- Showcase apps (reactive window-tree, etc.): a themed home under
  `900_EXAMPLES_SHOWCASE/` — the "cool things" gallery.
