---
type: belief
id: frag-a-backend-cache-keyed-on-mtime-can-serve-poison
provenance: 2026-08-15 — koru 172be12d backend cache; the airline bench gate build SIGABRT'd with ComptimeEventNotTransformed until ~/.cache/koru-backend-cache was cleared
ts: 2026-08-15
evolved: 2026-08-16 — content hash landed, THEN the key's COVERAGE missed the per-invocation generated compiler_env.zig; --lang=js backend served to zig builds (koru b90be9be → main.zig backendCacheKey fix)
evolved: 2026-10-05 — Fail 3: the key cannot see the koruc binary's own embedded backend template; a stale generator keys correct, poisons completely (K# vertical, cs stage-D)
evolved: 2026-10-11 — Fail 3 struck again: a pre-overlay koruc cached a stale-template backend under a current-src key; every later build's emitted program silently linked stock zig std. Fixed by hashing the emitted backend.zig + build_backend.zig into the key
evolved: 2026-10-30 — Fail 4: the key cannot see the TOOLCHAIN either; a glibc-2.34-bound backend built on another checkout was served to a glibc-2.31 host and failed at exec. The input closure now also includes the build target
---

# A backend binary cache can serve a poisoned kernel (belief)

`koruc`'s backend cache (172be12d) keys the reusable backend binary on
`src/` + `koru_std/` files. The assumption is that equal key ⇒ equal source ⇒
the cached backend is byte-fresh. The key must be BOTH faithful (equal
metadata/content ⇒ equal source) AND complete (every input that can change
the binary is in the key — including the generator's own embedded bytes).
It has now failed four times on four different axes.

**Fail 1 — faithful (mtime, 2026-08-15).** Keyed on path/size/mtime, a tree
in mid-motion races the rebuild: the first backend compiled from the
half-state gets cached under the new mtime hash and served to every
subsequent compile. The symptom is NOT a compile error — it is a compiler
**panic deep in the emitter** (`ComptimeEventNotTransformed` in `emitArgs`,
SIGABRT) on sources that built cleanly minutes earlier, indistinguishable
from a compiler regression. The room-building detail: the source repo was
UNCHANGED for the bench — failure between two builds with no source edit is
the tell. Fixed by content-hashing every file in the key (a partially-written
file's bytes can never equal the clean state, so the poison key cannot be
reproduced) and by `rm -rf ~/.cache/koru-backend-cache`.

**Fail 2 — complete (2026-08-16).** The content hash covered the roots, but
the key's roots were wrong: the backend compilation unit ALSO embeds
`compiler_env.zig` — the per-user struct (`.lang`, `.library`, flags,
env vars) generated into the OUTPUT directory on every invocation, imported
by the backend's build via `b.path("compiler_env.zig")`. It is the one
compiler-side input that lives outside `koru_home` and the key never saw it.
Consequence measured: `koruc input.k --lang=js` then `koruc input.k` (zig)
with a shared cache — the zig invocation got a CACHE HIT on the JS-baked
backend and produced `output_emitted.js` while its own generated
`compiler_env.zig` said `lang = "zig"`. Same family symptom: a compiler
failing on a totally ordinary build, attributable to nothing in the tree.
Missed for a day because the same session that hit it chased the panic as an
emitter bug first; the zig-vs-js cross-lang shape only surfaced when a zig
build "impossibly" took the JS path. Fixed by hashing the generated
compiler_env.zig into the key (FAIL LOUD: unreadable env file ⇒ cache
disabled, never a cross-invocation serve).

**Fail 3 — the generator is not a file (2026-10-05, the K# vertical).** The
key enumerates files: `src/`, `koru_std/`, the generated
`backend_output_emitted.zig`. But `backend.zig`'s *text* is not read from a
file — it is a string embedded in the **koruc binary**
(`generateBackendCode`'s emitted template inside `src/main.zig`, baked at
`zig build` time). A stale koruc writes backend text from an OLD template
while hashing the CURRENT `src/` — the entry is keyed correctly and poisoned
completely, because the input that changed (the template inside the binary)
has no file the key can see. Measured during the cs stage-D work: a
koruc built before `net9.0` → `net8.0` was edited cached a net9.0-emitting
backend under the net8.0 `src/` key; the fresh koruc hit it and produced an
apphost demanding a runtime the box does not have. The failure surface was
`.NET location:` complaining — three indirections from the actual cause,
which was *which binary ran an hour ago*. Same family tell: the symptom
names something (a missing framework) that no file in the key can explain.
Mitigation landed 2026-10-11 — and proven necessary by a second instance:
a pre-overlay koruc (no `__koruEnsureZigLibOverlay` in its template) cached
its stale backend under a post-overlay `src/` key; every later emitted
program was then compiled by that backend and silently linked **stock**
`std.json.Stringify` — the `--zig-lib-dir` overlay simply never ran, with
no error anywhere; the only tells were symbol tables and disassembly. The
fix is the simpler form of the self-hash idea: hash the emitted
`backend.zig` + `build_backend.zig` themselves into the key. The emitted
text IS the template's rendered bytes — keying on it captures emitter
version by construction, so a stale generator can only ever mint a key a
fresh one never looks up.

**Fail 4 — the toolchain is an input too (2026-10-30).** The shared
`/tmp/koru-regression-cache/koru-backend-cache` serves ONE flat directory to
every checkout on the machine. On a glibc-2.31 host (Ubuntu 20.04), a backend
built on a newer system — or built here before a target pin was in place —
is cached under a key that covers sources, env, and emitted text but NOT the
build target or the toolchain that produced the binary. The serve is
byte-valid source-fresh and exec-dead: `./backend: libc.so.6: version
'GLIBC_2.34' not found`. The symptom names libc, not the cache; the tell is
that the key is correct while the artifact is unrunnable — `objdump -T` the
entry and compare `GLIBC_*` against `ldd --version`. Same fix family:
`standardTargetOptions` accepts `-Dtarget=x86_64-linux-gnu.2.31` for every
`zig build`/`build-exe` — on this host, pin it (a PATH shim named `zig`,
since the harness invokes `zig` directly and `KORU_ZIG` only reaches koruc's
own spawns). The durable fix is to put the resolved target + zig version in
the key, the same way the emitted text went in: by construction, not faith.

The discipline that catches all four, retroactively: **enumerate what the
binary actually embeds — every file the compilation unit imports, every file
the build generates, every byte the generating binary itself carries, AND
the toolchain that links it — and put each one in the key by construction,
not by faith.** A cache entry is trusted state; anything less than a
complete input closure is a latent miscompile. Also: a compiler that starts
failing on unmodified input is not a compiler change; it is a cache or env
change — ask *which binary is actually running* before bisecting the tree.

## Related

- `frag-a-stale-binary-lies-like-a-compiler-bug` — the same family: two
  artifacts (here: cache entry vs actual source) that must agree, with
  nothing enforcing it. That one is koruc-vs-koru_std skew; this one is
  cache-vs-tree skew. The discipline for both is the same: before trusting a
  failing build, ask *which binary is actually running*.
- `frag-a-timeout-is-not-a-failure` — cold cache misread as a compile
  failure; the mirror image (cache presence misread as freshness).