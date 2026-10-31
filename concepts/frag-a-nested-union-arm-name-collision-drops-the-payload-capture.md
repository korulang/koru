---
type: belief
id: frag-a-nested-union-arm-name-collision-drops-the-payload-capture
provenance: symbolic quantity lanes — `add-sym`'s inner cov-join `| same g` emitted
  without `|g|` because `dim-eq`'s payload-free `| same` sat one level up; a 20-line
  probe reproduced it outside the quantity code
ts: 2026-10-31
tags: [koru, emitter, union-arms, name-collision, defect]
---

# A nested union arm loses its payload capture when an outer union already used the arm name (belief)

When a continuation unions on a tor whose arm name a sibling/outer union already
took with a *different* payload-ness — typically payload-free outside,
payload-bearing inside — the emitted Zig drops the inner `|binding|` capture.
The source is correct; the emit is wrong. `.same => |g| { … }` comes out as
`.same => { … g … }` and zig reports an undeclared identifier.

Minimal repro (worked at the time of writing, `probe.kz`):

```
~pub tor u1 { } | same | diff
~pub tor u2 { } | same string<io:!allocated> | other string<io:!allocated>
~go = u1()
| diff => ok
| same |> u2()
    | same g |> std/io:free(content: g) => ok
    | other g |> std/io:free(content: g) => ok
```

`go` emits the inner `.same` arm without `|g|`. Same-name `bad` arms collide the
same way: a payload-free `| bad` (sym:lit) shadows any later `| bad e` binding
(quantity:lit, mul, div) in the same emitted proc, so the caller cannot bind the
payload at all — `| bad x` goes undeclared — while `| bad` unbound is refused by
KORU030. The only consumer-side dodge today is renaming one side's arm.

The name collision is keyed on the arm NAME, not on payload-ness or position —
cov-join's `| indep g` and `| opp g` in the identical nested shape emitted
correctly; only `same` (which `dim-eq` had already emitted payload-free) lost
its capture. So the emitter keeps arm-name-keyed capture state across nested
switches; the fix belongs in `src/`'s emitter, not in call sites.

Consumer-side workarounds used in the symbolic quantity rung — all correct but
costly to a reader who doesn't know the rule:

- `cov-join|same` renamed to `| corr` (arguably the better name regardless —
  it is the *correlated* case, not "same" as in dim-eq).
- `unit-dim|bad` → `| bad-unit`, `cov-tag|bad` → `| bad-tag`,
  `lit-sym|bad` → `| bad-lit` at collision-prone sites.
- Tests that must bind a `| bad` payload cannot coexist with any payload-free
  `| bad` in the flow — so `symqty` smoke tests construct decimal operands via
  `lit-sym` (which arms `| bad-lit`) instead of `quantity:lit` (`| bad`).

Open question: does the defect also fire across *sibling* unions at the same
nesting depth, or only outer→inner? The quantity failure was always outer
(payload-free `same`/`bad` in an enclosing arm-set) → inner (payload-bearing).
A compiler fix should pin both directions.
