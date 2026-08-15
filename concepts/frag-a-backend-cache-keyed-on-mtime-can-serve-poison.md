---
type: belief
id: frag-a-backend-cache-keyed-on-mtime-can-serve-poison
provenance: 2026-08-15 — koru 172be12d backend cache; the airline bench gate build SIGABRT'd with ComptimeEventNotTransformed until ~/.cache/koru-backend-cache was cleared
ts: 2026-08-15
---

# A backend binary cache keyed on path+size+mtime can serve a poisoned kernel (belief)

`koruc`'s backend cache (172be12d) keys the reusable backend binary on
`src/` + `koru_std/` file path/size/mtime. The assumption is that equal
metadata ⇒ equal source ⇒ the cached backend is byte-fresh.

A tree in mid-motion breaks that. When `koru_std` or `src/` changes and a
rebuild races the edit (another session's `zig build`, a checkout mid-write),
the first backend compiled from the half-state gets cached under the new
mtime hash and served to every subsequent compile. The symptom is NOT a
compile error — it is a compiler **panic deep in the emitter**
(`ComptimeEventNotTransformed` in `emitArgs`, SIGABRT) on sources that built
cleanly minutes earlier. That shape is indistinguishable from a compiler
regression, and bisecting the koru commits finds nothing because the
regression is in the cache, not the tree.

The room-building detail this time: the source repo was UNCHANGED for the
bench (same `airline_tools.kz`, same gate). The failure appeared between two
builds with no source edit — which is the tell. A compiler that starts
failing on unmodified input is not a compiler change; it is a cache or env
change.

What fixed it: `rm -rf ~/.cache/koru-backend-cache` and rebuild — clean,
no code change. What would retire the class: key the cache on a HASH of the
input files' contents, not metadata; or validate the cached backend by a
self-test run before reuse (the 512-flow corpus would do).

## Related

- `frag-a-stale-binary-lies-like-a-compiler-bug` — the same family: two
  artifacts (here: cache entry vs actual source) that must agree, with
  nothing enforcing it. That one is koruc-vs-koru_std skew; this one is
  cache-vs-tree skew. The discipline for both is the same: before trusting a
  failing build, ask *which binary is actually running*.
- `frag-a-timeout-is-not-a-failure` — cold cache misread as a compile
  failure; the mirror image (cache presence misread as freshness).