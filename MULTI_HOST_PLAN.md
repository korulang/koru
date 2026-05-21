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

### Phase 2: Multi-extension file discovery

**Scope:** teach the resolver and file-discovery layer about `.k`, `.kjs`, `.kc`, etc. The parser itself does not change.

Plan refined 2026-05-22 after verifying all referenced line numbers against current `main`. Open in a fresh session — Phase 1 is fully landed; this is the next coherent piece.

**Code changes:**

- New `src/file_types.zig`: ~20-line module with the canonical extension list and two helpers.
  ```zig
  // Longest-first ordering so .kgpu matches before .k for greedy detection.
  pub const koru_extensions = [_][]const u8{ ".kgpu", ".kjs", ".kz", ".kc", ".k" };
  pub fn isKoruFile(name: []const u8) bool;
  pub fn koruExtensionOf(name: []const u8) ?[]const u8;  // returns the matching ext slice or null
  ```
  Hardcoded list — expand as new hosts are added. Avoid adding `config.zig` coupling; keep this as a pure module.

- **`src/module_resolver.zig`** — new helper `resolveKoruFile(allocator, base_path) !?[]const u8` that consolidates the existing inline "needs_ext / allocPrint / access" dance:
  - If `base_path` already has a Koru extension, `access()` it; return resolved path or null.
  - Otherwise iterate `koru_extensions`, `access()` each candidate, return the first that exists.
  - Caller decides how to handle null (set `result.file_path` or skip).

  Then swap the 8 callsites (all verified at these exact lines on `main` as of 2026-05-22):

  | Line | Current shape | Notes |
  |------|---------------|-------|
  | 276  | `if (!endsWith(entry.name, ".kz")) continue;` | Directory enum filter; change to `if (!isKoruFile(entry.name)) continue;` |
  | 369-384 | needs_ext + access + set file_path | Replace block with `resolveKoruFile` call |
  | 429-434 | needs_ext + access (inside `checkBoth` closure) | Same swap |
  | 561-... | needs_ext + access | Same swap |
  | 601-606 | **No access check today** — just appends `.kz` and returns | Multi-extension forces adding an `access()` here. Adds one stat() per absolute-path import. Acceptable cost. |
  | 633-657 | needs_ext + access | Same swap |
  | 686-710 | needs_ext + access | Same swap |
  | 737-... | needs_ext + access | Same swap |

- **`src/parser.zig`**:
  - Line 357: replace `if (endsWith(basename, ".kz")) { name_without_ext = basename[0..len-3]; }` with `if (koruExtensionOf(basename)) |ext| { name_without_ext = basename[0..basename.len - ext.len]; }`.
  - Line 7016: same swap inside the namespace-builder block.

- **`src/main.zig`**:
  - Lines 938, 940, 2799, 2801: replace `endsWith(args[1], ".kz")` (inside raw Zig string literals `\\`) with `isKoruFile(args[1])`. Note these are embedded in emitted Zig — the generated binary must also know about extensions.
  - Line 3189-3190: `if (endsWith(path_to_convert, ".kz"))` → use `koruExtensionOf`.
  - **Plan addition (not in original):** lines 3245-3248 build `parent_path` by appending `.kz` literally (e.g. `$std/io.kz` from `$std/io/file`). This needs to preserve the parent's actual extension. Strategy: try each extension at this site too, or first lookup the parent file's existing extension via filesystem. TBD during implementation.

**Estimated diff:** 80-100 lines net (down from inline-block count since `resolveKoruFile` consolidates 7 sites). Mechanical aside from the lines 3245-3248 nuance. No semantic changes elsewhere — the parser remains extension-agnostic.

**Tests** (new directory `tests/regression/100_FILE_LAYOUT/`):

- `SUCCESS`: module directory with `foo.kz` + `bar.kjs` resolves both files.
- `SUCCESS`: `~import "foo"` slurps all sibling `.k*` files when `foo/` is a directory.
- `SUCCESS`: a project with only `.kz` files keeps working identically (back-compat).
- (Add as discovered:) regression for the absolute-path stat() addition at line 601, and for the parent-path nuance at lines 3245-3248.

### Phase 3: Contract uniqueness rule

**Scope:** semantic check that enforces "if a `.k` file declares an event, no sibling host-file may re-declare it."

**Code changes:**

- Shape checker (or new dedicated pass): walk the module's AST after all sibling files are slurped; check for duplicate event declarations across files; if a `.k` file declared the event, the duplicate in a host file is the violation.
- Error message: `event 'compute' is declared in foo.k:N and re-declared in foo.kz:M. The .k file is the contract; remove the duplicate from foo.kz and keep only the proc body.`

**Estimated diff:** 10-20 lines in the shape checker pass.

**Tests:**

- `MUST_FAIL`: `.k` + `.kz` both declare same event.
- `SUCCESS`: `.k` declares event, `.kz` declares only `~proc` for that event.
- `SUCCESS`: `.k` declares event with NO implementation anywhere (partial-program tenet).
- `SUCCESS`: `.kz` declares event + proc inline, no `.k` file in module → works as today.

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
3. **Phase 3 once Phase 2 is in.** The duplicate-declaration check needs multi-file modules to exist first.
4. **Phase 4 last.** Tooling benefits from Phases 1-3 being settled; the tool's output needs to compile correctly under the new rules.

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
