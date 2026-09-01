---
type: belief
id: frag-koruc-must-not-clobber-foreign-build-zig
provenance: bettermaker pass 2026-09-01 — README hello at repo root silently replaced the compiler's tracked build.zig; doc routing to examples/greet was a workaround, not a fix
ts: 2026-09-01T01:10:00Z
---

# Koruc must refuse to overwrite a foreign build.zig beside the input (belief)

`koruc` emits `build.zig` in the same directory as the input file — convenience
for `zig build` on the generated backend. At the koru repo root that path is the
**compiler's** tracked `build.zig` (`pub fn build(b: *std.Build)`, `src/ast.zig`).
A newcomer following a hello example there got green output and a wrecked tree.

Routing hello through `examples/greet/` (019/README) stops the common case but
does not enforce it. The guard lives in `emit_build_zig.guardNonKoruBuildZig`:
if `build.zig` exists and is not koru-shaped (`__koru_b`), refuse with teaching.

Open: refusal happens after `backend.zig` / `build_backend.zig` are already
written — root still gets ignored scratch, just not a clobbered compiler build.
