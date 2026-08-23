---
type: belief
id: frag-a-bare-return-produce-is-an-escape-not-a-discharge-point
provenance: surfaced 2026-08-23 fixing 330_076/330_085 — auto_discharge_inserter read a subflow impl's bare-return produce as an "implicit terminator", appended the caller's disposer after its own `return r`, and emitted unreachable code naming an undeclared result
ts: 2026-08-23
---

# A bare-return produce is an escape, not a discharge point (belief)

When a subflow impl whose event declares `-> T` ends an arm on a bare-return
produce (`| stop r -> r`), the produced value crosses to the CALLER carrying its
obligation. Linear transfer means the terminus settles nothing: the caller's
consuming site or the caller's own discharge owns it from there. An inserter that
reads the produce as "end of pipeline, obligations live, insert disposal" commits
two sins at once — a semantic one (double discharge: caller discharges what the
callee already freed) and a mechanical one (the disposal lands after the arm's
`return r;`, so Zig sees unreachable code naming an undeclared result).

The branch-constructor twin of this credit already existed
(`bindingEscapesViaBranchConstructor`: obligations on fields the constructor hands
back are removed from the cleanup set). The expression twin was missing because
`.expression` nodes are not `.terminal`/`.branch_constructor`, so the produce
fell into the void-chain "implicit terminator" case written for
`~acquire() | ok r |> print.ln(...)` — a case where nothing escapes and insertion
is correct. One classification serving two shapes, wrong for exactly the shape
with a declared return.

## The general shape

An obligation dies three ways: discharged, dropped (a wall fires), or **escaped**.
Every pass that decides between insertion and no-insertion must enumerate all
three. Escape is the easy one to forget because its evidence is negative — the
code says `return`, not `dispose` — and because the checker upstream models it
correctly, so no diagnostic ever points at the inserter. The failure surfaces
only as emitted garbage two passes later, which reads as an emitter bug.

## Open questions

- Whether label-jump args and other non-terminal exits need the same explicit
  escape credit (some exists for back edges after 330_076's earlier repair).
- Whether the emitter should refuse to emit any continuation after a producing
  return — defense in depth that would have turned this defect into a loud
  compile error instead of undeclared-identifier noise.
