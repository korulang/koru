---
type: belief
id: frag-the-host-is-an-emission-detail
provenance: ruling session with Lars 2026-10-24 — 620_005 `:d:N` settled as Koru-owned
ts: 2026-10-24
---

# The host is an emission detail; surface semantics belong to the language (belief)

Where a Koru surface delegates its semantics verbatim to the backend — a
spec, an operator, a format — every emission target inherits (or must
re-correct) one host's quirk. Zig 0.15's `+` on width-formatted positive
signed ints reached the user through `{{ v:d:8 }}` because the spec passed
through untouched; C# and JS targets would each pay the same correction.

The rule: semantics are owned once in Koru — a lowering, a canonical
rewrite — unless delegation is ruled correct on the record. A waived
passthrough is a decided site (name why the host's semantic IS the
surface), never a skipped one. Multi-target is the thumb on the scale of
any cost-versus-benefit call: N backends paying for one non-decision
always loses to one lowering owned by the language.

The generator is challenge `029_the_host_leak_audit`: each run hoists or
waives one passthrough, pinned either way. Signed `%` → `@rem`
(2026-09-17) is the shape to copy.

Landed 2026-10-29: `:d:N` hoisted — the interpolation emitters rewrite
`d:<digits>` to `{f}` over `__koru_pad_i(N, arg)`, an emitted wrapper
that owns the padding (space-pad, sign only when negative); the spec
never reaches the host format string, and the check lives once in
`decimalPadWidth` (src/codegen_utils.zig). Pin: 620_005, green.

Measured the same sweep: the leak is wider than Zig's `+` — the C# and
JS placeholder emitters drop `d:N` SILENTLY (no width at all), and
`d:.N` (precision) still passes verbatim into `{d:.N}` on Zig. Signed
`/` (030_143) remains the next named exhibit.
