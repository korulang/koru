---
type: belief
id: frag-abstract-default-phase-inheritance
provenance: introduced by be07a826 — fix(abstract): preserve phase annotation on synthesized .default decls
ts: 2026-07-10
---

# A synthesized `.default` decl must inherit its abstract's phase annotation (belief)

When an `[abstract]` event has a cross-module override that delegates to the
original via `.default`, the resolution pass (`resolve_abstract_impl.zig:createDefaultEventDecl`)
synthesizes an `<event>.default` event decl. The emitter renders that decl as
the `<event>_default_event` member which the override's generated
`_default_handler` calls into. **That synthesized decl must carry the
abstract's own phase annotation (`comptime`), not merely `retain`** — otherwise
the emitter's EmitMode phase filter (`emitter_helpers.zig:shouldFilter`) drops
it in `comptime_only` mode and the member is never emitted, so the override's
`.default` delegation references a nonexistent member and fails to compile.

The subtlety that hid this for a long time, and the real variable — **not**
anything std-privileged: `shouldFilter` keeps a comptime-mode item when the
item **or its enclosing module** is `comptime`. `koru_std` modules carry a
blanket **module-level** `~[comptime]`, which masked a `.default` decl whose
own annotations had been stripped to `["retain"]` at synthesis — so
`coordinate.default` always emitted regardless. Externally-imported **user
libraries** mark comptime at the **item level** (`~[comptime|abstract]`) with
no module-level marker, so stripping the item annotation dropped the member and
silently broke `.default` delegation for every user-library abstract override
(the visible symptom: `struct '<lib>' has no member named '<event>_default_event'`).

The ruling: **phase is a property that must propagate from an abstract to its
synthesized `.default`.** The fix preserves the abstract's annotations and
appends `retain` (all of `hasRetain`/`shouldFilter`/`hasAnnotation` are
order-independent linear scans, so appending is safe). Module-level `comptime`
is not a substitute for propagation — it only ever *accidentally* hid the
absence of it.

Grounded by the `mini` minimal repro and the `koru/regressions:run` override
(see koru-libs); regression-guarded by the 430 coordination cluster. A
user-library abstract-override regression test in koru's own suite is still
owed (the corpus currently only exercises `.default` delegation via koru_std
modules, which is exactly why this stayed invisible).

Open question: whether other AST-synthesis sites strip annotations the same
way — only the `.default` synthesis path was audited here.
