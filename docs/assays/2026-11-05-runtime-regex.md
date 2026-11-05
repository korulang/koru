# Assay — what would runtime regex need?

- **Date**: 2026-11-05
- **Tree**: `55ad1a0f7` (assay-regex worktree, main)
- **Target**: capability-assay — *runtime regex*: patterns that arrive as
  runtime strings (user input, config, log formats), captures, and replace
  — vs what `std/regex` covers today. Named example in CHALLENGE.md.
- **Contestant**: devin (seat snow-yarrow @ w1C:p4T), 2 of 3

## The shape of the question

`std/regex` is a **compile-time** engine: pattern branches are surface
literals; a `[comptime|transform]` tor runs `regex.analyze` /
`compileToZig` per literal and emits a specialized matcher (KORU162 on
bad patterns). Runtime regex inverts one axis: the pattern is a `string`
whose bytes only exist at run time — so something must compile it *inside
the built program*, not inside `koruc`. The map scores: runtime pattern
compile, capture access, replace/substitution, and the consumers that
would use them.

## Exists

| # | Surface | Evidence |
|---|---------|----------|
| E1 | **`std/regex:match` — full-match dispatch, literal patterns, compile-time DFA.** Named groups `(?<name>…)` are the branch payload schema (strict 1:1 destructure, text→int conversion); capture matching is a **Pike VM over tagged NFA — already a runtime component**, linear-time, ReDoS-immune. | `koru_std/regex.kz` (464 lines), pins 640_001-640_012 |
| E2 | **`std/regex:scan` — unanchored streaming.** `!` pattern branch fires once per hit with the same named-group destructure; `| done` delivers count. Single pattern for now (multi-pattern pinned). | `koru_std/regex.scan.kz` (413 lines), pins 640_013-640_016 |
| E3 | **`koru-libs/pcre2` — runtime-compiled regex TODAY.** `libs/pcre2:compile(pattern: "…")` takes a **string pattern — runtime bytes — and compiles it inside the program** via libpcre2; `find.all` streams `! match` with per-iteration borrow; `group.text(m, index:)` reads captures; the compiled pattern is a phantom obligation (KORU030 refuses unfreed/reused). This is the whole runtime-regex shape already shipped — on a C substrate. | `~/src/koru-libs/pcre2/index.kz` header + usage (read-only survey) |
| E4 | **A consumer already riding it.** `koru-libs/winnow` (result shaping for tool output) builds its regex trio — `extract.lines`/`remove.lines`/`grep` — over koru/pcre2: "caller hands a bare pattern, winnow owns the whole-line wrap, compile, and free." Runtime patterns are in production use. | `~/src/koru-libs/winnow/index.kz` header |
| E5 | **The dependency-declaration surface pcre2 rides.** `~std/deps:requires.system { "name": "pcre2", "check": "pkg-config …" }` — a package declares its system lib and the build resolves it. Any C-substrate regex path inherits this. | `~/src/koru-libs/pcre2/index.kz:36-40` |
| E6 | **Refusal machinery for pattern errors.** KORU162 diagnostics name the pattern and the failure at compile time — the same shape a runtime compile tor wants for a `| err` arm (pcre2 already spells it: `| err e` → `e.msg`). | `koru_std/regex.kz:119-188`, pcre2 usage example |

## Missing-blocker

| # | Gap | Proof |
|---|-----|-------|
| B1 | **No dependency-free runtime pattern compile.** The pcre2 path exists (E3) but rides an external C library via `requires.system` — it cannot serve freestanding/JS/CS targets or a no-system-deps build, and it is a *package*, not `std/regex`. `std/regex`'s own compiler (`regex.analyze`/`compileToZig`) lives in the comptime transform, i.e., inside `koruc` — it is **not emitted into user binaries**, so no tor in the stdlib can compile a runtime `string` pattern today: the only engine that could do it ships only in the compiler. A dep-free `std/regex`-runtime path needs the analyzer+NFA generator lifted to a runtime-available form (or the Pike VM fed a runtime-compiled program) — that is a real piece of engine work, not a spelling. | cited: `koru_std/regex.kz:60` (`[comptime|transform]` — compile happens inside koruc); pcre2 requires `pkg-config libpcre2-8` |
| B2 | **No replace/substitution anywhere.** `match`/`scan`/`find.all` all *find* — no tor on either engine spells substitution (`re2::Replace`, `pcre2_substitute`, sed-`s` semantics). Winnow's line filters select or drop lines; nothing edits by pattern. A `replace` surface needs group-reference expansion (`\1`/`${name}` semantics — a ruling, not obvious). | cited: no replace/substitute tor in `koru_std/regex*.kz`, `pcre2/index.kz`, `winnow/index.kz` |

## Missing-but-portable

| # | Item | Why portable |
|---|------|--------------|
| P1 | **Multi-pattern scan** (leftmost-across-patterns). Pinned already — `640_016`; the scan transform itself names it "pinned as a follow-up" (`regex.scan.kz:51`). Same engine, wider dispatch. | cited refusal text |
| P2 | **Named-group access on the pcre2 path.** `group.text(m, index:)` is positional; named groups exist in PCRE2 (`pcre2_substring_get_byname`) — the lift is mechanical if named access is wanted there. | cited pcre2 C API surface |
| P3 | **orisha-side regex needs: none found.** Grep over `~/src/orisha/lib` for regex surfaces returned no usage — the router emits its own specialized dispatch (per the CLAUDE.md decisions: direct if/return chains, not regex). ConnCaps/router work does not block on this. | read-only survey |

## Recommendation

**Do NOT commission a dependency-free runtime engine yet — commission
`replace` and the multi-pattern scan first.** The expensive gap (B1) has a
shipped answer for every consumer that exists today: `koru-libs/pcre2`
compiles runtime strings, enforces custody in the type system, and is
already in production via winnow (E4). The dep-free version is real work
(the analyzer is compiler-side, not emitted) with **no current consumer
that pcre2 can't serve** — the honest trigger for B1 is a freestanding/JS
target needing runtime patterns, and none is on the board (P3).

Cost classes: **`replace` = stdlib surface, small-medium** — needs a
Lars ruling on group-reference spelling before any code (B2's open
semantic). **Multi-pattern scan = engine extension, small** — pinned
already, same machinery. **B1 = compiler/engine feature, large** —
commission only when a target the C substrate can't reach actually
appears. If the parked session wants "runtime regex" *inside std/regex*
for doctrinal purity, that's a design ruling to take back, not a gap the
map found un-served.
