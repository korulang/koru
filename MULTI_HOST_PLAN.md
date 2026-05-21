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

### Phase 1: Variant-mandatory

**Scope:** make naked `~proc name { ... }` unresolvable. Sweep existing procs to add `|zig` (or the appropriate host).

**Code changes:**

- Resolver behavior: if a proc declaration has no variant string and a call site has no explicit variant and no build mapping resolves to it, that's a compile-time error rather than the implicit-default fallback that exists today. The error message must teach: name the variant, suggest `|zig` for current code, point at the call site.
- The variant resolver itself stays the same (it already handles variant strings as opaque). Only the "fall back to bareword proc" path goes away.
- **Open question (decide in implementation):** when a call site has no variant and exactly ONE variant is defined, does the resolver pick it automatically? Design conversation favored YES (for migration ergonomics) — commit to that here unless evidence pushes otherwise.

**Mechanical sweep:**

- Repo-wide grep: ~326 procs in `koru_std/` + `demos/` + `dist/koru_std/`, ~1174 in `tests/regression/`, ~9 in `orisha/`. Total ~1500 proc declarations get `|zig` appended (or whatever host applies — the regression tests have some `|gpu` and `|js` already, leave those alone).
- The sweep is mechanical: regex-match `^~proc <name>(\s*\{|\s*$)` and replace with `^~proc <name>|zig`. The few existing variant procs need to be skipped.

**Tests** (new, under `tests/regression/300_ADVANCED_FEATURES/370_VARIANTS/`):

- `MUST_FAIL`: bare proc declaration with no variant + call site, no build mapping → "no resolvable variant" error.
- `SUCCESS`: bare proc declaration with no variant + zero call sites → compiles (partial-program tenet).
- `SUCCESS`: explicit variant + bare call site + only one variant defined → resolver picks it.
- `SUCCESS`: existing `8201_variants_basic` and `8205_zig_and_gpu_variants` continue to pass after the sweep.

### Phase 2: Multi-extension file discovery

**Scope:** teach the resolver and file-discovery layer about `.k`, `.kjs`, `.kc`, etc. The parser itself does not change.

**Code changes:**

- New `src/file_types.zig` (or addition to `config.zig`): canonical list of valid Koru file extensions, plus `isKoruFile(name)` and `koruExtensionOf(name)` helpers. Initial list: `[".k", ".kz", ".kjs", ".kc", ".kgpu"]`. Hardcoded; expand as new hosts are added.
- `src/module_resolver.zig:276`: directory enumeration filter changes from `endsWith(".kz")` to `isKoruFile(name)`.
- `src/module_resolver.zig:369, 429, 561, 601, 633, 686, 737`: the "add `.kz` if needed" patterns become "try each Koru extension in order until one resolves" OR "fail with explicit-extension-required error." Recommend the former for ergonomics.
- `src/parser.zig:357, 7016`: module name derivation strips any Koru extension via `koruExtensionOf()`, not just `.kz`.
- `src/main.zig:938, 940, 2799, 2801, 3189`: input-file detection uses `isKoruFile()`.

**Estimated diff:** 60-80 lines across `module_resolver.zig`, `parser.zig`, `main.zig`. Mechanical. No semantic changes — the parser remains extension-agnostic.

**Tests** (new directory, e.g. `tests/regression/100_FILE_LAYOUT/`):

- `SUCCESS`: module directory with `foo.kz` + `bar.kjs` resolves both files.
- `SUCCESS`: `~import "foo"` slurps all sibling `.k*` files when `foo/` is a directory.
- `SUCCESS`: a project with only `.kz` files keeps working identically (back-compat).

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
