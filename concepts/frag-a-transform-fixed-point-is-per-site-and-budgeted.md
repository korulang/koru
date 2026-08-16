---
type: belief
id: frag-a-transform-fixed-point-is-per-site-and-budgeted
provenance: session 2026-08-15 — the store scale wall (game world population)
ts: 2026-08-15
tags: [koru, transform-runner, scale, emitted-size]
---

# The transform fixed point is per-site and budgeted; the TIME wall is the final Zig ReleaseFast build (belief)

Two separate scale costs on a program with N literal transform flows, and
they have different fixes and different shapes:

1. THE PASS BUDGET (crash, FIXED 2026-08-15). The transform fixed point
   applies ONE transform per pass (`walkOnce` returns after the first found;
   deterministic single-write ordering), so N transformable sites need N
   passes, and the loop breaker was a FIXED 1000. A store with 1024 literal
   `std/store:insert` flows (no kernel) is a finite program needing >1000
   passes — it died with a misleading `TransformInfiniteLoop` after 58s of
   finite work. The breaker is now an honest budget (100_000) with a message
   naming both readings; 1024 flows compile (~68s); a genuine re-firing loop
   still terminates loudly after a bounded burn.

2. THE TIME WALL (measured, FINAL): three components, and the pass cost
   IS the quadratic. Sampling koruc and its backend child (2026-08-15):
   (a) the transform PASSES run in the backend child and take ~16s at 512
   literal flows, hot in `transform_pass_runner.countMatchingInFlow` under
   the koru_std comptime events (evaluate_comptime/elaborate) — whole-flow
   counting per transform site, O(N²)-ish. (b) the FINAL `zig build-exe
   output_emitted.zig -O ReleaseFast` adds ~4.4s (the emitted file is only
   ~190KB at 512 flows — ~370B/flow, not 12KB; the 6.5MB was the BACKEND's
   embedded koru_std). (c) the backend ITSELF is rebuilt per run by
   `zig build --build-file build_backend.zig` (~11.6s) — a reusable
   artifact whose own design comment says it is reusable — now CACHED (a
   binary cache keyed on src/ + koru_std/ file mtimes; hit copies
   zig-out/bin/backend and skips the build; ~33s → ~21s per run). Earlier
   in this session a "passes are fast (0.43s)" reading was an artifact of
   a run that aborted at a failed zig spawn: the passes were never that
   fast. The pass cost (countMatchingInFlow's repeated whole-flow counting)
   is the remaining blocker for literal per-flow population; batching or
   count-caching is now the correct target.

The blessed bulk path stands and bypasses BOTH: the LOOP population form
(`for(0..N) ! each i |> insert(...)`) is ONE flow, ONE pass, and a small
emitted artifact — a 1,048,576-row store compiles near-instantly while a
literal-1024 population takes ~68s. Literal per-flow population is the
anti-pattern for large data.

The pass cost was profiled FOR REAL with a decisive control: 512 plain
`std/io:print` flows compile in 0.9s, while 512 literal `std/store:insert`
flows take 22.1s — a ~25x STORE-SPECIFIC cost with a superlinear slope
(7.4s at 128, 11.0 at 256, 22.1 at 512, hyperfine-stable, cached
backend). The wall is neither the runner's matching (a set-hoist A/B
measured 0%: 20.41s pre vs 20.43s post) nor generic interpreted comptime:
it is the STORE transform's per-site WHOLE-PROGRAM scans
(`storeCollectWriteSet` / `storeScanCont` / `storeCollectAliases`,
walking every flow + continuation per stored site — store.kz), each
application paying O(program) in scans. The naive fix is REJECTED on honesty grounds (ruled 2026-08-15): MEMOIZING
those scans is not acceptable unless extremely honestly bounded. The scans
feed CORRECTNESS-CRITICAL emission (per-column-set write specializations,
store-name and write-set resolution across the whole subtree), and the
program MUTATES EVERY PASS — so any memo's invalidation is either as
expensive as the program itself (content-verify the key, which costs
roughly the scan) or stale-behavior hazard (a cache served against a
per-pass-mutating input = silently wrong emitted code, the exact class of
quiet green this repo refuses). A cache keyed on less than the full
program state is a correctness lie wearing a speed patch. The honest
alternatives: (a) accept the cost and keep the LOOP-form population as the
blessed path for large literal data (one flow, one pass, fast); (b) narrow
a scan ONLY if it is proven semantically equivalent under the full-program
view (short-circuiting an answer the scan itself defines — not a cache and
not an abbreviation of a genuine whole-program answer). The
100_000-site-budget fix and the backend-binary (content-keyed) cache are
the landed wins; the store scans stay uncached by design.

The backend cache gained one hardening requirement from use: it is keyed on
file mtimes, and a mid-edit rebuild can cache POISON (a backend built from
half-written sources) that later runs serve — a rebuild with mtimes that
happen to match serves the poisoned binary until the cache is cleared.
The key must incorporate file CONTENT (hashes), not just mtimes, so a
partially-written source can never match the future clean state.

## The first blessed instance — the per-pass snapshot index (2026-08-16)

The rejection above names the one allowed speedup: a scan narrowed ONLY if
provably equivalent under the full-program view. The first such narrowing
is live. `walkOnce` builds the program's `[expand]` event-decl set ONCE per
pass, and `handleExpandIfMatches` queries it per node instead of scanning
the whole program per un-transformed invocation. This is NOT the rejected
cache: the fixed point applies one transform per pass, so the program is
byte-immutable for the entire walk, and the index is rebuilt at the top of
every pass — it can never be served against a program it was not built
from. Same predicate, same program order, first match wins: the answers
ARE the scan's own answers, demonstrated, not argued — old vs new backend
on the same 512-flow AST emit byte-identical output_emitted.zig (the exes
differ only in the Mach-O UUID). The index is threaded down the walk BY
VALUE rather than by `&expand` pointer: address-taking + a passed pointer
down the deep self-recursive walk was observed to be corrupted to a
code-segment address in one layout, deterministically flipping
115_047_vendor_bindings_in_module; the value copy (24 bytes) is trivial
next to the scan it replaces and cannot alias across recursion frames.

Measured (512-literal store, backend runs, shared binary per column):
128 flows 7.44 -> 5.64s · 256 9.68 -> 7.63s · 512 19.87 -> 10.1s; the
512-print control went 0.81 -> 0.46s. The superlinear slope flattening
(256->512 was 2.05x, now 1.42x) is the per-node scan collapsing to an
empty-list check in the common no-`[expand]` program.

The attribution correction that came with it: the measured top layer of
the wall was the RUNNER's per-node full-program scan in
`handleExpandIfMatches` (~44% of samples) — not the store transforms'
own scans (`storeCollectWriteSet`/`storeScanCont`/`storeCollectAliases`
sat at ~0.5% in the same profile) — amplified by per-pass program growth
(inserts append machinery; prints do not). A dead 256-byte `debug_path`
buffer built per invocation for a commented-out log line went with it.
After the fix the store's OWN per-site machinery resurfaces as the next
layer: the `stored`/`insert` whole-program probes and text rewrites (BMH
preprocess churn, the `flatItems` clusters) — the same per-pass-snapshot
proof applies to transform handlers once the snapshot reaches them through
the handler ctx.