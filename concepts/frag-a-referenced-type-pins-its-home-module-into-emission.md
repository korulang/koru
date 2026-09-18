---
type: belief
id: frag-a-referenced-type-pins-its-home-module-into-emission
provenance: 667_005 — `std/foreign:struct(File)` in a same-file import left `*koru_app.koru_lib.File` dangling in emitted output; fixed by `collectTypeHomeModules` in visitor_emitter (2026-09-11)
ts: 2026-09-11
---

# A signature-referenced type pins its home module into emission (belief)

`collectModulesRecursively` decides whether a module enters the emitted file by
asking `moduleHasEmittableItems` — a runtime-surface question: events, flows,
host code that wants emitting. The answer was treated as a completeness test for
the whole module, and it is not. A module can contribute something that emits
while contributing nothing that counts: a host TYPE. A `.kz` whose whole payload
is `const File = struct {…}` plus a comptime `std/foreign:struct` registration
holds the declaration every `*File` in an emitted signature is qualified to
(`*koru_app.koru_lib.File` — the cross-module spelling of
[[frag-bare-host-type-is-module-local-cross-module-is-qualified]]), and the
collector dropped it while the qualification still fired. The emitted file
named a module it never wrote.

The invariant the emitter now maintains: **any base type named by an emitted
signature — event input, bare return, branch payload, host-type field —
pins its `host_type_homes` module into the collected set**, fixpointed because
a backfilled module's own signatures can reach further homes. "Emittable" is
no longer a property of a module's item list; it is a property of what the rest
of the program *references* in it.

The same conflation is worth watching for anywhere a collection pass treats
"has items I would emit" as "contributes nothing": emission is a reference
closure, and a declaration-only module is exactly where the closure's edges
terminate.

Measured 2026-09-16 (orisha + openssl consumer): the closure's edge was wrong
in the other direction too. A QUALIFIED spelling `?std.mem.Allocator` was
reduced to its last segment and fed to the same bare-name map — and
`const Allocator = std.mem.Allocator`, a private convenience alias inside
`[comptime]` std.compiler, had claimed `Allocator` first. Every consumer with
an allocator parameter welded the whole compiler module (imports of `ast`,
`log`, the pass machinery) into its runtime binary. Resolution now matches
how a reader resolves the spelling: **a qualified type names its own module**
(`std.mem.*` — no koru home, no pin; `orisha.Request` — orisha pins), and
`host_type_homes` is the fallback for bare names only. The map's first-wins
collision semantics are untouched — that ambiguity was already the contract
([[frag-bare-host-type-is-module-local-cross-module-is-qualified]] is the
spelling side).

Refinement 2026-09-18: the type string alone lies twice more, both fixed the
same way — prefer structural qualifier evidence over the bare-name map. A
resolved field splits its qualifier into `field.module_path` and leaves
`.type` bare (`*Item`), so a scan that reads only the string feeds a
qualified reference to the first-wins map anyway. And a bare name inside a
module's OWN signature is module-local (220_031) — when the scanning module
declares it, that module is the home, no lookup. The remaining failure mode
was worse than the earlier allocator weld: `std.compiler`'s host block
declares `const Item = ast.Item` at column 0, and the injected bootstrap
import always walks first, so any user type sharing an AST name (`Item`,
`Program`, `Source`) welded the whole compiler module — test-gen bodies
included — into the program unit, where its `log`/`ast` bindings dangle.
A consumer found it: a domain type named `Item` in a `.k` program failed
zig codegen on `log.verbose`. Pinned at 220_039.

Open: the scan still reads type STRINGS — a compound spelling like
`[]const [N]T` or `*const fn(...)void` names no home at all and escapes the
closure. No pin exercises that yet.

Refinement 2026-09-18: the reference surface had a dead zone — host-language
`pub const X = struct { f: module/path:Type }` decls were verbatim bytes, so
a `domain/events:NoteRegionJSON` inside one emitted into Zig untranslated
(`error: expected ',' after field`) and registered nothing even when spelled
as the emitted path (`koru_domain.koru_events.X` — the module was never
pulled). The invariant's fix was NOT in the backfill, which already scans
host_type_decl fields; it was upstream: a decl that wants to carry a module
reference must be PARSED, not passed through. The parser now lifts
`pub const X = struct` blocks into HostTypeDecl under a deliberately narrow
grammar (`name: Type` fields, comments, commas — anything else falls back
to host_line passthrough byte-identically), splitting `module:Type` into
module_path exactly as tor signatures do. Then the existing machinery does
the rest for free: writeFieldType emits the qualified Zig path and the
type-home backfill pulls the referenced module. Pinned at 220_040 — a host
struct field is the ONLY reference naming app/lib in that test. The general
lesson: passthrough is where references go to die; any host-text surface
that authors want to name cross-module types from must become an AST
surface first.
