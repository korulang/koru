---
type: belief
id: frag-proc-body-module-scope-spelling
provenance: surfaced building @korulang/raylib (koru-libs) 2026-07-17 — the frames `! frame` proc hit the inline-scope hole on day one, and the sqlite3/pcre2 root-path workarounds were found stale/fragile; fixed by the $mod. emitter contract (400_155)
ts: 2026-07-17
---

# `$mod.` is the one spelling for a |zig proc body's own module scope — bare words collide, root-paths rot (belief)

Cut-1 effect inlining (Lars-ratified 2026-06-12) splices an effect tor's
proc body into the CONSUMER's frame: one frame, no Handlers struct, no
namespace boundary. Its scope-portability contract covered params, effect
names, and `std.` (rewritten to `@import("std").`) — but said nothing about
the proc's OWN module scope (cimports, module types, helper fns), which
every effect-branch lib proc needs. Libs filled the hole with
`@import("root").koru_libs.<member>` reaches into emitter-internal naming.

## Why this bit us

The emitter's member mangling grew a `koru_` prefix at some point after
sqlite3's reach was written; `koru_libs.sqlite3` stopped resolving and
sqlite3's whole row-iteration path (query.literal) died — pinned red in
query_parameterized.kz but attributed there only to the bare-`Statement`
scope gap, so the second breakage layer sat invisible under the first.
pcre2 carried the same reach behind a `px.` alias. The root-path reach is a
disguised route-around: it couples every lib to an emitter internal that is
free to change, and when it changed, nothing errored at the koru level.

## The rule this establishes

- `$mod.` in a `~proc |zig` body names the declaring module's scope, under
  EVERY lowering: the splice path rewrites it to the module's emitted
  namespace (same boundary-checked scanner as the `std.` rewrite; prefix
  logic shared with call-target emission via emitInvocationModulePrefix),
  and the Handlers-fn path strips it to bare names (the body already sits
  in module scope lexically). Pin: 400_155 exercises both paths.
- The spelling MUST be sigiled. Bare words died empirically the same day
  they were tried: `self.` mangled real Zig method receivers
  (koru_std/deps.kz semver compare), `mod.` collides with capture locals
  (koru_std/compiler.kz). `$` cannot appear in a Zig identifier, so
  collision with real code is impossible by construction — the only sound
  shape for a textual rewrite contract over opaque Zig text.
- Lib code never reaches through `@import("root").koru_libs.*`. Existing
  reaches are migration debt (sqlite3 + pcre2 converted 2026-07-17).

## Open

- The sqlite3 `~query` comptime TRANSFORM still emits generated inline code
  referencing `@import("root").koru_libs.sqlite3` (stale). Transform-
  generated inline code is a different emission path (ast.Flow.inline_body)
  not covered by the proc-body rewrite — needs its own ruling: extend
  `$mod.`-style substitution to transform output, or give transforms a
  first-class way to name their module.
- A pit-of-success diagnostic could flag `@import("root").koru_libs.` inside
  proc bodies at the koru level ("emitter-internal — use $mod.").
