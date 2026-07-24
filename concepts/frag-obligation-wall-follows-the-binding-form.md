---
type: belief
id: frag-obligation-wall-follows-the-binding-form
provenance: surfaced 2026-07-24 by the THE LANTERN demo (demos/lantern) — a text adventure whose one game rule is a phantom obligation; pinned red as 330_113
ts: 2026-07-24
---

# The undischarged-obligation wall follows the BINDING FORM, not the obligation (repudiation)

We believed the wall was a property of the obligation: mint `<lit!>`, fail to
discharge it, get `KORU030 … was not discharged`. `330_025` reads that way, and
so does every phantom test that drops a resource on the floor.

It is a property of **how the minting call is bound**. The check reaches
auto-minted `_auto_N` temporaries — the anonymous drop — and does not reach a
value captured into a **named** binding. The same `light()` call, same
`<lit!>`, same never-discharged end of flow:

- dropped bare → rejected, `KORU030`, resource named `_auto_0`
- captured as `light(): lamp |> …` → **compiles clean, binary runs, lantern
  stays lit**

Giving the resource a name is the only difference between the two programs.
That is the wrong axis for a safety wall to be sensitive to, and it is the
ergonomic form — you name a resource precisely when you intend to *use* it —
that falls through.

`330_113` pins the escaping form red (`must-fail-passed`); `330_025` holds the
accepted form. Auto-discharge is disabled in the pin so the wall itself is
under test: with LIFO auto-discharge on (the default), the compiler inserts the
missing `douse` and the question never gets asked.

## Why this hid for so long

Auto-discharge is the default, and it is *correct* on this program — it emits
the `douse` and the lantern goes out. So the gap is invisible unless you
explicitly turn the insertion off, which almost nothing does. The default
masking the wall is not a bug in the default; it does mean the wall itself has
been under-exercised, and the obligation-stress clusters inherit that blind
spot wherever they bind results to names.

## Open

Whether the fix belongs in the obligation finder (teach it to walk named
bindings live at end-of-flow) or earlier, at the point where a capture inherits
the phantom set from the call's return type, is undecided. The second reading
suspects the obligation is not on `lamp` at all — that the capture drops the
phantom rather than the checker skipping it — and those two produce very
different fixes. Determine which before building.
