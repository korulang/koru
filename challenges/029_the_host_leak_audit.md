---
challenge: host-leak-audit
kind: frame
status: standing
yields: one site where a Koru surface delegates semantics to the host backend, hoisted into Koru or explicitly waived — pinned either way
family: emitter
created: 2026-10-24
---

*Walker context — the recurrence that earned this frame. `{{ v:d:8 }}` passed
its spec verbatim into Zig's format string, and Zig 0.15 prints an explicit
`+` on width-formatted positive signed integers. Every external oracle
(CLBG, PLB nsieve) expects space-pad, sign-only-when-negative — the pin
`620_005` sat red for months holding the surface while the mechanism
question was parked. Ruled 2026-10-24: Koru owns `:d:N`, because C# and JS
are separate emission targets — a spec passed verbatim makes every backend
inherit (or re-correct) one host's quirk.*

## The frame

Each run finds ONE site where a Koru surface semantic is decided by the
host — a verbatim passthrough into emitted code — and resolves it:

- **Hoist**: implement the semantic in Koru (a lowering rule, a canonical
  rewrite) with a pin. Preferred default — the host is an emission detail;
  the surface belongs to the language.
- **Waive**: rule delegation correct *on the record* — name why the host's
  semantic IS the surface (e.g. IEEE float printing), in the pin or a
  concept. A waived site is a decided site, not a skipped one.

## Candidate sites (start here, then sweep)

- `:d:N` width spec — DONE 2026-10-29 (`{f}` + `__koru_pad_i`, one `decimalPadWidth` predicate at all five Zig interpolation sites; 620_005 green, a95587991). CS/JS drop the spec outright — filed `030_fmt_spec_width_csjs`. `d:.N` precision still passes verbatim on Zig — unmeasured.
- Signed runtime `/` — raw Zig error leaks (030_143, still parked — its
  ruling is the hoist vs refuse question itself).
- Signed `%` — DONE 2026-09-17 (`@rem`), the shape to copy.
- Sweep for more: `rg` the emitter for spec/text that reaches the backend
  verbatim — format specs, escapes, numeric formatting, intrinsics.

## Discipline

Cost-versus-benefit is the stated test, not a blanket "always hoist" —
but multi-target is the thumb on the scale: a semantic owned once in Koru
is correct in Zig, C#, and JS; a passthrough is N backends paying for one
non-decision. Each yield names its check that could falsify (a pin that
fails if the host behavior shows through).
