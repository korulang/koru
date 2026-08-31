# Plan: kebab-case + `/`-separators + stage-aware stdlib restructuring

Status: **design lock-in**. No `src/` or `koru_std/` edits yet. This document is
the agreed shape before any code moves. Compiler edits need explicit go-ahead.

Branch: `kebab-stdlib-restructure` (worktree `../koru-kebab-stdlib`).
Base: `9d83920a` (`.k`-pure tip, const-free — rebased clean per D5).

---

## 0. Why (one paragraph)

Every objection we raised against kebab dissolved on contact with the code:
mangling-collision (names like `[GET /]` are *generation payloads*, not Zig
symbols), parse-speed (the name/expression decision is already positional, no
lookahead), and diagnostic-leak (FLOW anchors already carry the way back).
What survived — the proc-implementer crossing `a-thing`→`a_thing` — turns out
to be the *same* boundary friction we already decided we want. Pulling that
thread surfaced a bigger, better-grounded win: the call site spells modules
*differently from the import* (`import "std/io"` then `std.io:...`), `.` is
overloaded three ways, and the metacircular stage split (comptime transforms
run in the backend, can't compile in pipeline code) isn't reflected anywhere in
the namespace. This plan fixes all of it as one coherent move.

---

## 1a. Empirical state — pins run 2026-06-03 (CORRECTS earlier framing)

Running the §10 pins demolished two assumptions. What's ACTUALLY true:

- **Kebab already PARSES** in event/field names. The gap is **emission**: kebab
  event names leak raw (`pub const my-event_event = struct` → invalid Zig);
  kebab fields emit as Zig-quoted `@"a-thing"`, not the snake `a_thing` the proc
  body expects. (Pins 050, 051 red at backend, not frontend.)
- **`/`-namespace already PARSES + RESOLVES.** `std/io:print.ln` works today
  (FLOW anchor `~std/io:print.impl()`, correct output). (Pin 052 GREEN.)
- **`_` still accepted; `println` still exists.** (Pins 053, 054 red — real work.)
- **Harness discovers tests by `input.kz` only** — pure-`.k` entry support lived
  in the dropped const commit (`33e66e74`). `.k`-only tests aren't run here.

**Reframe:** Track B is NOT "make the parser accept kebab" — it's **emit mangle
(`-`→`_`, kill the `@"..."` quoting + the raw leak) + tightening (reject `_`)**.
Track A's `/`-acceptance is already free; its work is the **corpus codemod
(`.`→`/`)**, killing `println`, the **stage facets**, and eventually tightening
`.` out of namespace position.

Pin status: 050 🔴 · 051 🔴 · 052 🟢(coverage) · 053 🔴 · 054 🔴.

## 1. Confirmed decisions (locked)

- **Kebab-case**: `-` becomes a legal name-char. `| my-branch b |>`,
  `~pub event delete { directory-name: string }`.
- **`/` for namespaces at call sites**: the call site spells the module the same
  way you import it and the same way it sits on disk. `std/io:print.ln`, not
  `std.io:print.ln`.
- **Stage-aware stdlib facets**: `std/io:*` (user-stage) vs `std/compiler:*`
  (transform-free, safe in code that runs *as part of* compilation). Same leaf
  names where the concept matches; the path tells you the stage.
- **Kill `std/io:println`**: it's a nerfed (non-interpolating) `print.ln`.
  Greenfield → no nerfed twin.
- **`_` is no longer a name-char**: makes the `-`→`_` mangle lossless/bijective.
  (`_` survival in *numeric literals* is OPEN — see D1.)
- **Bare import paths**: `import std/io`, not `import "std/io"`. The quotes were
  vestigial (a module path is an identifier-path, not a string). Unifies the
  import spelling with the call-site (`std/io:`) and the filesystem (`std/io.k`)
  — one path, one spelling everywhere. Commits to: import paths are ALWAYS
  identifier-paths (no extensions / `../` / spaces). Parser change + corpus
  codemod (`import "X"` → `import X`).

---

## 2. Decisions — RESOLVED

- **D1 — `_` in numeric literals: KEEP digit separators.** `123_456` legal,
  `foo_bar` rejected. `_` has exactly one residual job (digit grouping), never a
  name-char. The asymmetry is the only thing a reader must be taught.

- **D2 — JS mangle: snake for Zig, camelCase for JS.** `directory-name` →
  `directory_name` (Zig) / `directoryName` (JS). Deterministic rule + its one
  edge (`-<digit>`) specified in §7.

- **D3 — Identifier-class scope:** all name classes per §4. Host type names stay
  host-shaped. Phantom states adopt `-` by **convention** (compiler treats them
  as opaque strings — not enforced).

- **D4 — `:` stays overloaded (3 jobs), accepted.** Module pivot / named-arg /
  format-spec — all positionally unambiguous; one concept ("bind a name to a
  thing") in three hats. Conscious keep.

- **D5 — Base: rebased onto `9d83920a` (clean, const-free). Done.** Const lands
  on its own track. (R1 resolved.)

---

## 3. The four-glyph separator system (spec)

Each glyph, exactly one job. This is the de-overloading payoff.

| Glyph | Job | Example | Maps to Zig |
|-------|-----|---------|-------------|
| `/` | namespace hierarchy (= import string = filesystem) | `std/io` | `.` (module access) |
| `:` | module → symbol pivot (importable boundary) | `std/io:print` | `.` (member) |
| `.` | descend-into-group / member access | `print.ln`, `final.acc.count` | `.` (field/member) |
| `-` | word-glue *inside* a single name | `my-event`, `z-buffer` | `_` |

Reads cleanly because each boundary-kind is distinct:
`std/io:z-buffer.render` = pkg `std/io`, symbol `z-buffer`, member `render`.

Lexer notes:
- `-` is a name-char ONLY in name position. In a bare expression (`|> a-b`,
  forwarded verbatim to host), `-` stays minus. The two positions are already
  syntactically distinct (trailing `(`/`{` test, `parser.zig:6035`), so **no
  added lookahead**.
- `/` must coexist with `//` line comments and `/* */`. Single-char lookahead,
  Zig-precedented. (Task in §6.)

---

## 4. Identifier-class scope (D3 detail)

| Class | Kebab? | Rationale |
|-------|--------|-----------|
| Event names | ✅ | generation payloads / lower to wrapped symbols |
| Branch names | ✅ | `\| my-branch` |
| Bindings | ✅ | `\| ok my-val \|>` |
| Struct/payload fields | ✅ | bare-snake mangle, no marker (struct-scoped) |
| `const {}` decl names | ✅ | symbol-bearing; the `_`-ban bijection proof site |
| Proc names | ✅ | mirror their event |
| Module / file names | ✅ | `my-module` ↔ `my-module.k` (fs allows `-`) |
| Labels `@loop` `#anchor` | ✅ (already!) | `lexer.zig:643,659` already accept `-` |
| Phantom states `<...>` | ✅ by convention | opaque strings to the compiler — `-` adopted as a naming convention, not enforced |
| **Host type names** (`*Resource`, `[]const u8`) | ❌ | these ARE host identifiers; kebab here would fight the host. Under the `string`→`[]const u8` type-system direction, Koru type *aliases* could be kebab, but raw host types stay host-shaped. |

---

## 5. Stage facets + the `println` kill (spec)

Three print citizens after the change:

```
std/io:print.ln        comptime transform, zero-overhead, USER code only
std/compiler:print.ln  runtime-formatted interpolation, COMPILE-TIME-safe
(std/io:println)        DELETED — subsumed by print.ln
```

`std/compiler` contract: **every symbol under it is implemented transform-free,
so it is callable from code that runs as part of compilation** (sits next to
what `compiler.kz` already reaches for). Same leaf names as the `std/io`
counterparts where the concept matches.

**Interpolation-once invariant (law, must be enforced):** the comptime pass
scans the *template literal* for `{{ }}`; a runtime value spliced via `{{ x:s }}`
is inserted **verbatim, never re-scanned**. This is what makes
`print.ln("{{ h.html:s }}")` safe when `h.html` itself contains `{{ }}`.

`println` migration (grounded from corpus):
- ~vast majority pass string literals → flat rename `println(text: "x")` →
  `print.ln("x")`.
- handful pass runtime vars (`h.html`, `a`) → wrap: `print.ln("{{ h.html:s }}")`.
- caller stage decides facet: user-code callers → `std/io:print.ln`;
  compile-time callers (e.g. parts of `build.kz` — **confirm stage first**) →
  `std/compiler:print.ln`.

---

## 6. Guardrails (build them WITH the change, not after)

- **G1 — stage rejection.** A `[comptime|transform]` symbol invoked in
  pipeline-stage source → hard front-end error: *"`print.ln` is a comptime
  transform; it expands in the backend, which is what this code is. Use the
  `std/compiler` facet."* This is surfacing a bootstrap *impossibility*, not a
  style rule.
- **G2 — `std/compiler` is transform-free by construction.** Declaring or using
  a `[comptime|transform]` under `std/compiler` is rejected.
- **G3 — interpolation-once** (§5 invariant) enforced in the transform.
- **G4 — `_`-in-name rejection** with a demangle-aware hint:
  *"`foo_bar` is not a legal name — use `foo-bar` (underscores are reserved for
  digit separators)."*

---

## 7. Mangle spec

Source name → host symbol. Lossless under the `_`-ban.

- **Zig**: `directory-name` → `directory_name`. Top-level symbols also carry the
  existing `koru_` wrapper (Phase 2). Demangle = strip known `koru_` prefix,
  then `_`→`-`. Bijective.
- **JS** (`.kjs`): `directory-name` → `directoryName`. Rule: lowercase the first
  hyphen-delimited word, capitalize the first letter of each subsequent word,
  drop hyphens. Reversible (source is all-lowercase kebab → demangle splits on
  caps). **Edge — `-<digit>`:** no letter to capitalize, so `run-session-2` →
  `runSession2`, whose naive demangle (`run-session2`) loses the last hyphen.
  Resolve in Track B step 4: either forbid a `-` immediately before a digit in
  names, or carry a marker. (Zig is unaffected — `run_session_2` round-trips.)
- **Fields** mangle to *bare* snake — no `koru_`, no `__lowered_` marker
  (struct-scoped → no collision, can't be cross-called, provenance via container
  + FLOW anchor). Keeps proc bodies reading like normal host code.

---

## 8. Implementation sequence

Two orthogonal tracks; either can land first.

**Track A — separators + stdlib facets (the higher-grounded win):**
1. Stand up `std/compiler` facet with transform-free `print.ln` (+ whatever
   compile-time code actually needs).
2. Land G1/G2 (stage rejection) so misuse is loud.
3. `/`-namespace at call sites: parser accepts `std/io:` form; mangle `/`→`.`.
   Lexer `/` vs `//` handling.
4. Codemod corpus call sites `.`→`/` (automated, §9).
5. Codemod `println` → `print.ln` / `std/compiler:print.ln` by caller stage.
6. Delete `println`. Old tests go red = the migration to-do list (greenfield).

**Track B — kebab:**
1. Pin reds (§10).
2. Add `-` to `isValidIdentifier` (`lexer.zig:68,72`) + path-scan
   (`parser.zig:6046`); flip branch/binding validators (`4942`, `5010`).
3. D1 decision → `_`-in-name rejection (G4) + numeric-literal predicate.
4. Mangle `-`→`_` (D2 for JS).
5. Codemod corpus snake→kebab for in-scope classes (§4, §9).
6. Tooling sweep: `generate-stdlib.js`, skill/doc generators.

---

## 9. Codemod strategy

Scale: low-hundreds of corpus files. **Automated, not hand edits.**
- Separator codemod (`.`→`/` in module-path position): mechanical, scoped to the
  `<pkg>:` prefix — must NOT touch `.` in member position (`print.ln`,
  `final.acc.count`).
- Kebab codemod (`_`→`-` in in-scope name classes): trickier — must distinguish
  name positions from numeric literals and host type names. Likely an
  AST-driven rewrite, not regex.
- Run full suite `--no-cache --parallel 8` after each codemod wave; reds are the
  worklist.

---

## 10. Test anchors (pin RED first — "failing test before the fix")

- `010_xxx_kebab_branch_name` — `| my-branch b |>` MUST_RUN (parser rejects today).
- `010_xxx_kebab_event_field` — `~pub event my-stuff { a-thing: string }` +
  proc accessing `payload.a_thing` MUST_RUN.
- `010_xxx_slash_namespace` — `std/io:print.ln(...)` MUST_RUN.
- `010_xxx_reject_underscore_name` — `foo_bar` MUST_FAIL with G4 hint.
- `010_xxx_stage_reject_transform_in_pipeline` — comptime transform in
  pipeline-stage code MUST_FAIL with G1 message.
- `010_xxx_println_gone` — `std/io:println(...)` MUST_FAIL (symbol deleted).
- `010_055_bare_import` — `import std/io` MUST_RUN (parser accepts bare path).

---

## 11. Risks / in-flight collisions

- **R1 — RESOLVED.** Rebased onto clean `9d83920a`; const WIP dropped from this
  branch. Const fixes land on their own track.
- **R2 — `=>` construct-glyph work is in progress** with its own codemod over
  the same call-site / parser surfaces. Coordinate merge order or we double-edit
  the same lines. Land `=>` first, or explicitly interleave.
- **R3 — const-block kebab** depends on the const transform working (§ R1).
  Kebab in `const {}` decls is downstream of that fix.
- **R4 — codemod blast radius** vs the regression cache: use `--no-cache` after
  waves (cache keys on inputs; mass rewrites invalidate broadly anyway).
