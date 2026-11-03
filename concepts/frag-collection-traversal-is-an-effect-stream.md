---
type: belief
id: frag-collection-traversal-is-an-effect-stream
provenance: commissioned key-iteration session 2026-11-03 — ruled by Lars
  same day ("iteration is an '! each' effect arm — NOT a keys() proc"), built
  as std/string-map:each + std/map:each, pinned by 660_034/660_035
ts: 2026-11-03
---

# Collection traversal is an effect stream, not an accessor (belief)

**The ruling (Lars, 2026-11-03): iterating a collection's entries is spelled
as a tor that delivers `!` effect arms — never a proc returning a buffer of
keys or values.** `std/string-map:each(m) ! pair { k, v }` and
`std/map:each(m) ! pair { k, v }` are the first collection instances of an
idiom that predates them: `std/fs:read-lines` delivers `! line`,
`std/string:split` delivers `! piece`, `std/control:for` delivers `! each`,
`std/store:preorder` delivers `! preorder`.

Why this shape and not `keys()`:

- **An owned-buffer return is the structural leaker read-lines already
  proved.** A tor handing back `[][]const u8` gives the caller memory no
  Koru surface can free. The effect arm borrows for the handler's extent
  instead — `! pair`'s `k` is a view into the table's owned key bytes, zero
  allocation, dead when the handler returns.
- **The after-traversal summary is a terminal arm, not part of the stream.**
  `| done` delivers the pair count; produce-during (`!`) and return-after
  (`|`) are the same split `for` and `read-lines` keep.

Two vocabulary facts this surfaced, kept so they don't get re-researched:

- A record-typed effect payload is first-class grammar, not a special case —
  `! pair { k: string, v: i64 }` declares the arm, `pair(.{ .k = …, .v = … })`
  fires it inside the proc's `|zig` body, `! pair { k, v }` destructures at
  the site. Pinned by 020_018 long before the map surface existed.
- There is no receiver-form call this rung — `m:each` is unspellable;
  traversal is namespaced like every other collection op
  (`std/string-map:each(m)`).

Open:

- **Mutation during traversal is unguarded at the type level.** `set` inside
  `! pair` borrows the same `<map>` the traversal holds, and a grow rehashes
  and invalidates the Zig iterator — UB nothing checks (only `free` is
  barred, by `<!map>`). Documented on the surface; a checked answer (an
  iterating phantom, or a fenced mutation set) is undecided.
- Iteration order is hash order — unstable. Sorted output is a downstream
  composition, not a surface the map owes.
