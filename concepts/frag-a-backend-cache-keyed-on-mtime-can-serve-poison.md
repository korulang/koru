---
type: belief
id: frag-a-backend-cache-keyed-on-mtime-can-serve-poison
provenance: 2026-08-15 — koru 172be12d backend cache; the airline bench gate build SIGABRT'd with ComptimeEventNotTransformed until ~/.cache/koru-backend-cache was cleared
ts: 2026-08-15
evolved: 2026-08-16 — content hash landed, THEN the key's COVERAGE missed the per-invocation generated compiler_env.zig; --lang=js backend served to zig builds (koru b90be9be → main.zig backendCacheKey fix)
---

# A backend binary cache can serve a poisoned kernel (belief)

`koruc`'s backend cache (172be12d) keys the reusable backend binary on
`src/` + `koru_std/` files. The assumption is that equal key ⇒ equal source ⇒
the cached backend is byte-fresh. The key must be BOTH faithful (equal
metadata/content ⇒ equal source) AND complete (every input that can change
the binary is in the key). It has now failed once on each half.

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

The discipline that catches both, retroactively: **enumerate what the binary
actually embeds — every file the compilation unit imports, including files
the build generates — and put each one in the key by construction, not by
faith.** A cache entry is trusted state; anything less than a complete input
closure is a latent miscompile. Also: a compiler that starts failing on
unmodified input is not a compiler change; it is a cache or env change —
ask *which binary is actually running* before bisecting the tree.

## Related

- `frag-a-stale-binary-lies-like-a-compiler-bug` — the same family: two
  artifacts (here: cache entry vs actual source) that must agree, with
  nothing enforcing it. That one is koruc-vs-koru_std skew; this one is
  cache-vs-tree skew. The discipline for both is the same: before trusting a
  failing build, ask *which binary is actually running*.
- `frag-a-timeout-is-not-a-failure` — cold cache misread as a compile
  failure; the mirror image (cache presence misread as freshness).