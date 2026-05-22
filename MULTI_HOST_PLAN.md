# Multi-Host Plan

A design + implementation plan for making Koru genuinely multi-host at the language and file-system level. Captures decisions from a design conversation on 2026-05-21 so future sessions can execute without reconstructing the rationale.

**End state:** Koru is a bounded contract (events, flows, types, obligations) that can talk to multiple host languages simultaneously, with file-system organization that reflects which host owns which implementation. Zig is the current default host, but the language stops privileging it at every layer.

---

## Context

Today, Koru has a `~proc name { ... }` form where the brace body is host-language code (Zig by convention). It also supports `~proc name|variant { ... }` for multi-variant implementations (see `tests/regression/300_ADVANCED_FEATURES/370_VARIANTS/`, especially `8201_variants_basic` and `8205_zig_and_gpu_variants`). The variant system treats variant strings as opaque — `|zig`, `|gpu`, `|js` all work, and bodies can be in different host languages because proc bodies are opaque to the Koru parser (see this repo's CLAUDE.md, "Koru is emit-only with the host language").

What's missing:

- Naked `~proc name { ... }` defaults to "Zig body" implicitly. The language privileges Zig at this layer.
- All files share a single `.kz` extension. The "this file is Koru with Zig bodies" convention is implicit.
- Migration between hosts requires polyglot files with Zig and GLSL and JavaScript side by side.

---

## Design moves

Four design choices, each independently motivated, in service of the same goal: make Koru's multi-host story load-bearing at every layer instead of opt-in.

### Move 1: Variant-mandatory (parseable but unresolvable)

Make `~proc name { ... }` (no variant) parseable but **unresolvable**.

- **Parser unchanged.** The grammar still accepts the bare form.
- **Semantic rule (new):** if no variant string is declared on a proc, no call site can resolve to it. The bareword proc is dead until something explicit (a variant tag, a build mapping) points to it.

**Why:**

- The "default to Zig" pattern hides what's actually happening — the body is in a *host*, and which host is a real choice. Implicit defaults that hide choices are the same shape as Koru's other ceremony rejections: `| name { x: T }` rejected (use `| name T`), solo `| done` branches rejected (use void), mid-chain comments rejected (KORU010). Same principle: when the implicit shortcut hides what's happening, the explicit form is the only legal form.
- Extends the "branches are equal" principle one level down: no host is privileged. Zig is one host of many.

**Why parseable-but-unresolvable, not illegal:**

- Reserves the bareword form for a future **universal body language** in pure Koru that compiles to any host. If that ships, `~proc compute { ... }` becomes "the body is in Koru's portable language; emit for any target." The syntactic slot is held now without committing what fills it later.

### Move 2: Multi-extension file layout

Introduce file extensions that name the host:

- `.k` — pure Koru. Event declarations, types, obligations. **No proc bodies.**
- `.kz` — Koru with Zig bodies. As today.
- `.kjs` — Koru with JavaScript bodies.
- `.kc`, `.kgpu`, etc. — Koru with C / GLSL / CUDA / etc. bodies.

The convention: K + host-language abbreviation. The parser doesn't care which file something is in; the file extension is purely organizational.

**Why:**

- The contract has a single source of truth. The `.k` file holds the event signature *once*; each host's implementation lives in its own file. Implementations can't drift from the contract because the contract is one declaration, not many.
- Migration becomes mechanical. Extract events to `.k`, write a `.kjs` alongside the `.kz`, cross-test, deprecate. Each step is small.
- Cross-host property testing falls out: `compute|zig` in `compute.kz` and `compute|js` in `compute.kjs` can be fuzzed with the same inputs, equivalence checked.
- The file extension signals cognitive mode. Opening `foo.kjs` tells you "JavaScript inside braces." Opening `foo.k` tells you "no host, this is the contract."

### Move 3: Contract uniqueness rule

If a `.k` file in a module declares an event, no sibling host-file in the same module may re-declare the same event.

**Why:**

- Enforces "single source of truth for the contract." Without this rule, the `.k` file would be decorative.
- Composes with Koru's partial-program tenet: an event declared in `.k` with no implementation in any host file is fine, as long as nobody calls it. Migration states are always valid.

### Move 4: Migration tool

Ship `koruc make-portable <file.kz>` (or similar): given a `.kz` file, extract all event declarations to a sibling `.k` file, leave the proc bodies in `.kz`.

**Why:**

- Mechanical migration without a big-bang rewrite. Run the tool, get a working state with the contract extracted, iterate from there.

---

## Explicitly deferred

**The universal body language.** Move 1 reserves the syntactic slot for it; Move 2 reserves `.k` as its natural home. **We are NOT implementing it in this work.** It's a much bigger piece for later — a real Koru-native body language that compiles to multiple hosts. The reserved slots make it forward-compatible; nothing in this plan commits to building it.

**Inter-variant linking compatibility.** The capability where `foo|c` and `bar|zig` can be auto-linked because they share C ABI, or `foo|js` and `bar|ts` can interop because they share a runtime. Build-step rules for compatible-implementation pairing. Mentioned in the design conversation as something the architecture enables; not in this plan's scope.

---

## Implementation phases

Each phase is independently shippable. The partial-program tenet means intermediate states are valid: nothing breaks if Phase 1 lands but Phase 2 hasn't.

### Phase 1: Variant-mandatory — **LANDED 2026-05-22**

Landed on `main` across commits `70905a38` (sweep), `6511e5af` (resolver), `5083e05a` (followup), `00e2243f` / `ca0bba25` (test-fixture corrections). Final suite state: **507/540 in-scope passing (93.9%)**, identical failure count to pre-Phase-1 baseline (22 pre-existing failures, none introduced).

**What shipped:**

- New error code `KORU110` in `src/errors.zig` ("Variant / multi-host" category, gap-filling between `KORU100` binding and the unused-200 range).
- New check in `src/flow_checker.zig` (`validateInvocationResolution` + `checkInvocationVariants`): for each invocation in a flow, walk all `proc_decl`s (top-level + inside `module_decl.items`) matching the path. If at least one matches AND every match has `target == null` → emit `KORU110` with a teaching hint suggesting `|zig`.
- 1321 bare `~proc` declarations across `koru_std/` + `tests/` + sibling repo `orisha/lib/` tagged with `|zig`. `dist/` excluded (gitignored, regenerates).
- Two new regression tests under `tests/regression/300_ADVANCED_FEATURES/370_VARIANTS/`: `8211_bare_proc_call_site_fails` (MUST_FAIL + pinned `expected.txt`) and `8212_bare_proc_no_call_site_succeeds` (COMPILE_ONLY, partial-program tenet).

**Decisions made during implementation:**

- **Abstract events exempt.** Procs implementing an event annotated `[abstract]` are skipped — the abstract-override mechanism is a distinct resolution path. Exemption lives in `checkInvocationVariants`: lookup the event via `findEventDecl`; if it has the `abstract` annotation, return without checking.
- **Single-variant auto-resolution = YES.** Already true in practice after the sweep — every event has its `|zig` variant and the existing emitter picks `|zig` as the default when no variant is registered. No emitter change needed for Phase 1.
- **Colon-qualified `~proc name:event { ... }` not retagged.** The abstract-event-override syntax (e.g. `~proc input:greet`) is exempted via the `[abstract]` event annotation, not via path inspection. The parser inconsistency where `is_impl` isn't set on `ProcDecl` (it is on `Flow`) is a separate known issue, deferred.
- **Multi-variant disambiguation deferred.** The case `|zig` + `|gpu` + bare call site → ambiguous. Existing emitter handles it via the "default to zig" path; tightening that is a follow-up beyond Phase 1's scope.

**Followup lessons learned (read these before the next big sweep):**

1. **Original regex was too narrow.** `^~proc <name>` missed `~[pure] proc`, `~[comptime] proc`, `~[runtime] proc`, `~[inline] proc`, `~[comptime|runtime] proc`, `~pub proc`. Caught and fixed across 15 sites. Use this regex going forward:
   ```
   ^(~(?:pub\s+|\[[^\]]+\]\s*)+proc\s+[\w.*]+)(?![\w.*|:])    # annotated forms
   ^(~proc\s+[\w.*]+)(?![\w.*|:])                              # plain
   ```
2. **Programmatic `ProcDecl` constructions need `target` too.** Three sites synthesize ProcDecl directly: `koru_std/kernel.kz` (lines 947, 1039 — `kernel_init_*` from the comptime kernel transform) and `koru_std/parser_generator.kz:179`. All three default `target` to null. Caused `KORU110` to fire at stage C with synthesized event names like `kernel_init_2255387733`. Any new transform that synthesizes procs must set `target = "zig"`.
3. **MUST_FAIL form-under-test is sacrosanct.** `tests/regression/000_CORE_LANGUAGE/020_EVENTS_FLOWS/020_012_reject_pub_proc` exists to verify `~pub proc` is rejected. The sweep mechanically tagged it `~pub proc greet|zig {`, then `expected.txt` was refreshed to match — the test kept passing but no longer exercised the form it claimed to. Restored. Captured in memory as `feedback_must_fail_sweep_exclusion.md`. Next sweep must skip MUST_FAIL files whose target line is the rejected form.
4. **Sibling-repo sweep needed too.** `~/src/orisha/lib/` had bare procs the koru sweep couldn't reach. Always cross-check sibling repos when koru regression tests import them (e.g. `350_*` orisha router tests).

### Phase 2: Multi-extension file discovery — **LANDED 2026-05-22**

Landed on branch `phase-2-multi-extension`. Final suite state: **511/544 in-scope passing (93.9%)**, identical failure count to pre-Phase-2 baseline (22 pre-existing failures, none introduced; +4 new tests under `100_MODULE_SYSTEM/140_FILE_LAYOUT/`).

**What shipped:**

- New `src/file_types.zig` (~60 lines including 4 unit tests). Canonical extension list — longest-first ordering for greedy matching:
  ```zig
  pub const koru_extensions = [_][]const u8{ ".kgpu", ".kjs", ".kz", ".kc", ".k" };
  pub fn isKoruFile(name: []const u8) bool;
  pub fn koruExtensionOf(name: []const u8) ?[]const u8;  // longest-first match
  ```
  Hardcoded list — pure module, no `config.zig` coupling. Wired into `build.zig` with its own `file_extension_tests` target (the name `file_types_tests` was already taken by an unrelated File/EmbedFile AST test).

- **`src/module_resolver.zig`** — two new helpers consolidate the previous "needs_ext / allocPrint / access" dance:
  - `pub fn resolveKoruFile(allocator, base_path) !?[]u8` — probes Koru extensions on an absolute path.
  - `pub fn resolveKoruFileIn(allocator, base, name) !?[]u8` — probes extensions for `<base>/<name>`.

  All 8 callsites swapped (verified line numbers held). The line 601-606 absolute-path branch now does an `access()` it didn't before — old behavior was "blindly append `.kz` and return without checking" which masked broken imports as downstream file-open errors. Now returns `error.ModuleNotFound` cleanly.

- **`src/parser.zig`** — 4 sites (plan undercounted by 2): the original 357 and 7018, plus the parallel block at 7030 (non-aliased import namespace) and 7081 (directory enumeration). All swap `endsWith(basename, ".kz")` → `koruExtensionOf(basename)` with `basename[0..basename.len - ext.len]`.

- **`src/main.zig`** — 6 sites (plan listed 5):
  - Lines 945-950, 2806-2811 (was 938-940, 2799-2801): embedded raw Zig string literals emit a multi-line `endsWith` OR chain across all five Koru extensions. The generated backend binary must recognize Koru source files independently of the compiler.
  - Line 3190: `koruExtensionOf` swap.
  - Line 3245-3248 (the flagged wrinkle for parent_path) — strategy chosen: probe each extension at the caller via new `probeImportExtensions` helper.
  - Line 3321 (`index_path` builder for auto-import) — same wrinkle, same strategy.
  - Line 3405 (basename eql `"index.kz"` in submodule enumeration) — replaced with a stripped-basename equality check using `koruExtensionOf`.
  - Line 3438: `koruExtensionOf` swap for `submod_name`.
  - Line 3528 (loading `<dir>/index.kz` as the directory's source) — swapped to `resolveKoruFileIn(allocator, dir, "index")`.

- **Generator updates** (Phase 2 also touches the metacircular build emission). 6 places emit `build_backend.zig`-shaped code that declares the koru `src/` modules; each gained a `file_types_module` declaration and an `addImport("file_types", file_types_module)` on both `module_resolver_module` and `parser_module`:
  - `koru_std/build.zig`
  - `koru_std/build_backend.zig`
  - `koru_std/compiler.kz`
  - `koru_std/parser.kz`
  - `koru_std/interpreter.kz`
  - `koru_std/backend.zig` (the embedded `\\`-prefixed string template)

  Missing this is what broke ~470 tests on the first build — the koruc compiler itself compiled fine, but every test's metacircular backend compilation failed with `no module named 'file_types' available within module 'parser'`. The 6-generator update brought the pass rate back to baseline + 4.

**Tests (`tests/regression/100_MODULE_SYSTEM/140_FILE_LAYOUT/`):**

The plan suggested top-level `100_FILE_LAYOUT/` but `100_` was already taken — placed under `100_MODULE_SYSTEM/140_FILE_LAYOUT/` to keep related discovery tests together.

- `140_001_kjs_extension_import` — `.kjs` helper resolves as a sibling import (the analog of `110_001_file_import_basic`).
- `140_002_k_pure_contract` — `.k` file with only event declarations; COMPILE_ONLY (partial-program tenet).
- `140_003_directory_mixed_extensions` — directory containing both `alpha.kz` and `beta.kjs`; both load, both events emit output.
- `140_004_index_kjs_directory_source` — directory whose source file is `index.kjs` instead of `index.kz`; resolves correctly.

Back-compat is implicitly proven by the 507 pre-existing `.kz`-only tests continuing to pass through the new code paths.

**Decisions made during implementation:**

- **Probe order = match order.** Used the same longest-first ordering (`.kgpu, .kjs, .kz, .kc, .k`) for both extension recognition AND file-system probing. A separate probe order biased toward `.kz` would save 2 wasted stat() calls per legacy import, but adds dual-ordering complexity. The 2 stat() calls are negligible compared to actual file parsing; revisit only if profiling demands it.
- **Absolute-path resolution now fails loudly.** Old `resolve()` blindly returned the path with `.kz` appended without checking; downstream file-open errors hid the bad import. New behavior returns `error.ModuleNotFound` at resolution time, matching how other paths fail.
- **Probe-via-resolver helper lives in `main.zig`.** `probeImportExtensions` takes an alias-prefixed stem (`$std/io`) and tries each extension through `resolver.resolveBoth`. Distinct from `resolveKoruFile`/`resolveKoruFileIn` which operate on filesystem paths directly. Different layers, different helpers.
- **Index-file probing extends to all sites.** `queueIndexImport` (3321), the submodule-enumeration skip (3405), and the directory-source loader (3528) all now know that `index.<ext>` may use any Koru extension, not just `.kz`. The `index` convention is now multi-extension-aware end-to-end.

**Followup lessons learned (read before any future addImport-style sweep):**

1. **Generator sweep must accompany source sweep.** Anything that adds a new module to `src/` must also propagate the declaration through all 6 metacircular generators. The compiler itself building successfully says nothing about whether per-test backend compilation will succeed. Always run at least one regression test after a module addition before declaring the build clean.
2. **Plan-quoted line tables undercount.** The plan listed 8 + 2 + 5 = 15 sites; reality was 8 + 4 + 6 = 18. `grep -nE '"\.kz"|endsWith.*\.kz'` over the three files immediately surfaced the extras. Always grep before trusting a line-number table from a prior session.
3. **`index.kz` is a third-class identifier alongside `endsWith(".kz")`.** The literal string `"index.kz"` appears in basename equality checks and `allocPrint` calls; pure regex sweeps for `\.kz` miss them. Grep both `\.kz` and `index\.kz` patterns.

### Phase 3: Contract / implementation event location rule

**Refined 2026-05-22** after a design conversation that narrowed the original "no events at all in host files" framing into a pub/private split. The narrower rule preserves subflow ergonomics while still making the public surface of a module a literal file you can read.

**The rule (two statements, fire as a pair):**

1. **Events in `.k` must be `~pub`.** Private events in `.k` are illegal. A private declaration in a contract file is dead syntax — no procs live in `.k` (those are implementation), so nothing inside `.k` can call a private event, and nothing outside can see it.
2. **When `.k` exists, sibling implementation files (`.kz`, `.kjs`, `.kc`, `.kgpu`) cannot declare `~pub event`.** They can still declare non-public events — internal subflow scaffolding is preserved. Public events live in `.k` exclusively.

**Both rules fire only when `.k` is present in the module.** No `.k`? Today's behavior holds: implementation files can have public events freely. The rule is opt-in per module, and migration cost is zero — existing single-file `.kz` projects keep working.

**Orthogonal to variants — explicitly:** A single `.kz` containing `~proc foo|zig { ... }`, `~proc foo|gpu { ... }`, and `~proc foo|js { ... }` mixed inside is fine and will keep being fine. The rule is about *where public event declarations live*, not about which host languages a given file can mix. A `.kz` that's a companion to a `.k` can absolutely have variant-soup procs inside; what it can't have is `~pub event` declarations. The two axes (file-extension split vs in-file variant mixing) are independent organizational choices.

**Why pub/private (vs the original "no events at all" framing):**

- A bare "no events in host file" rule would force all helper events into the public `.k` contract OR force subflows to be inline-only. Both are bad: the contract gets polluted with internal scaffolding, or subflows lose composability.
- The pub/private split lets `.k` stay clean (only public events) while `.kz` keeps its private events for internal subflow plumbing. Implementation expressivity is preserved; public surface is still a literal file you can read.

**Precondition (must land before Phase 3):**

The silent first-wins collision at `src/type_registry.zig:178-184` (`if (self.events.get(path)) |existing| { return; }`) needs to become a real error. Today, if two files in the same canonical namespace both register an event under the same path, the second is silently dropped. This masks the Phase 3 violation case (`.k` and `.kz` both declare `~pub event compute`) at the registry layer, so the Phase 3 check would only fire if it ran *before* registry population. Cleaner: registry hard-errors on unexpected duplicate registration; Phase 3's check fires earlier (during merge or shape-checking) and produces a domain-specific error before the registry sees the collision.

This precondition is its own small commit, can ship independently, and fixes a real "silent fallback" antipattern regardless of whether Phase 3 ever lands.

**Code changes (Phase 3 proper):**

- New error code: probably `KORU111` (continuing the variant-mandatory `KORU110` family). `KORU200` is already taken by ambiguous-module.
- Check location: shape_checker is the natural home — it runs after AST canonicalization and has access to all module items. Needs each `EventDecl` to carry its source file (probably already in `SourceLocation`; verify during implementation).
- Two checks, both fired per merged module that contains a `.k` file:
  1. Walk `.k` items, error on any `EventDecl` where `is_public == false`.
  2. Walk implementation-file items, error on any `EventDecl` where `is_public == true`.

**Estimated diff:** 30-50 lines in the shape checker pass + the `KORU111` definition + 2 test fixtures. The precondition (registry hardening) is another ~10 lines.

**Tests** (extends `tests/regression/100_MODULE_SYSTEM/140_FILE_LAYOUT/`):

- `MUST_FAIL`: `.k` file declares a private event (`~event foo`, no `~pub`) → `KORU111` "private event in contract file."
- `MUST_FAIL`: `.k` declares `~pub event compute`, `.kz` also declares `~pub event compute` → `KORU111` "public event in implementation file."
- `SUCCESS`: `.k` has `~pub event compute`, `.kz` has only `~proc compute|zig { ... }` and a private `~event _helper` for an internal subflow.
- `SUCCESS`: `.k` declares event with NO implementation anywhere (partial-program tenet).
- `SUCCESS`: `.kz` declares `~pub event` + proc inline, no `.k` file in module → works as today (rule is opt-in).
- `SUCCESS`: `.k` + `.kz` where the `.kz` mixes `~proc foo|zig`, `~proc foo|gpu`, `~proc foo|js` — the variant-mixing axis is orthogonal to the contract-split axis.

**Open questions to resolve during implementation (don't pre-decide):**

1. **Imports in `.k` for typed payloads.** An event like `~pub event create_user { role: Role }` references a user-defined type. If `Role` lives in another module, `.k` would need to import. The two-rule Phase 3 doesn't restrict imports, so this isn't blocked — but the natural extension is "contracts can import other contracts (other `.k` files)." Defer the decision; cross the bridge when a test demands it.
2. **What else belongs in `.k`?** The design conversation deliberately narrowed scope to events. Whether `.k` should also be restricted to *only* events (no top-level Zig blocks, no annotations, no module-level constants) is a separate question. Address piecemeal as the need arises.
3. **Inter-host implementation pairing.** If `.k` + `.kz` + `.kjs` all coexist, and `.kjs` only implements *some* of the events declared in `.k`, that's a partial-program state — still legal, only the uncalled events stay unresolvable per Phase 1's rule. Confirm during implementation that the resolution check handles this gracefully (it should already, since variant resolution is per-call-site).

### Phase 4: Migration tool

**Scope:** `koruc make-portable <file.kz>` extracts events to `<file.k>`, leaves proc bodies in `<file.kz>`.

**Code changes:**

- New subcommand in `src/main.zig` (the command-parsing area near line 1382).
- Reuses existing parser to walk the AST, splits event declarations from proc declarations, writes the two files.

**Estimated diff:** ~200 lines for the tool + tests.

**Tests:**

- Round-trip: `make-portable foo.kz` → `foo.k` + `foo.kz` → compiles identically to original `foo.kz`.
- Idempotence: running `make-portable` twice does nothing the second time.

---

## Testing strategy

Phase-by-phase regression tests as outlined above. The existing variant test suite (`tests/regression/300_ADVANCED_FEATURES/370_VARIANTS/`) is the natural home for Phase 1 additions. Phases 2-3 get a new directory under `tests/regression/100_FILE_LAYOUT/` or similar. Phase 4 lives under tooling tests.

**Cross-host property testing as a capability** falls out of the design but doesn't need its own implementation — once you can declare `compute|zig` and `compute|js` in sibling files, the test framework can already fuzz both with the same inputs and assert output equivalence. No new test infrastructure needed.

---

## Sequencing

1. **Phase 1 first.** Smallest contained change; immediately validates the "variants as primary host axis" framing. Sweep is mechanical but large (~1500 procs); good first session because it's contained and reversible.
2. **Phase 2 second.** Builds file-discovery infrastructure without requiring Phase 3's semantic rule. Can ship in isolation; multi-file modules with `.k` files become *possible* but not yet *enforced*.
3. **Phase 3 precondition: registry-collision hygiene.** Turn the silent first-wins skip in `src/type_registry.zig:178-184` into a hard error on unexpected duplicate registration. Its own small commit, lands independently, fixes a real silent-fallback antipattern.
4. **Phase 3 once the precondition is in.** The two-rule contract/implementation event location check fires during shape-checking. Needs Phase 2 (multi-file modules exist) and the precondition (registry doesn't mask the violation).
5. **Phase 4 last.** Tooling benefits from Phases 1-3 being settled; the tool's output needs to compile correctly under the new rules.

Each phase ships as its own commit (or PR-shaped unit). Don't bundle them. The regression suite proves each phase independently.

---

## Open questions to resolve in implementation

1. **Single-variant auto-resolution.** Phase 1, above. Decide YES unless implementation reveals otherwise.
2. **File-extension list: hardcoded vs pattern.** Phase 2. Recommend hardcoded list initially; revisit if the host language ecosystem grows fast.
3. **Module-name derivation when multiple files share a basename.** If `foo.k`, `foo.kz`, `foo.kjs` all exist in the same directory, the module is `foo` and all three contribute. Confirm in implementation; should be the default behavior after Phase 2.

---

## Design rationale provenance

This plan came out of a design conversation on 2026-05-21 between Lars (language designer) and Claude (implementing co-author). The conversation also produced the blog post `/blog/ai-first-bordering-on-ai-native`, which is shipped and stands as the public framing of why these moves matter. The plan here is the private engineering counterpart to that post: same design principles, focused on implementation.

Key conversational anchors, in case future-me needs to reconstruct:

- The "AI-first, bordering on AI-native" frame motivates these moves because they push more of Koru's identity into structural choices (file layout, mandatory variants) and out of conventions (Zig as the implicit default).
- The "branches are equal" principle from this repo's CLAUDE.md ("there is no happy path") extends one level down to "hosts are equal" — Zig is one host of many.
- The partial-program tenet (declared events without implementations compile fine if uncalled) makes the multi-file split and the parseable-but-unresolvable variant rule both ergonomic to migrate into.
