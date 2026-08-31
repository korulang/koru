# Repository Guidelines

## Project Structure & Module Organization
- `src/` is the metacircular compiler pipeline; wire passes in `build.zig` and trace dependencies.
- `lib/`, `libs/` for runtime/backends; `koru_std/` is the standard library (`KORU_STDLIB`).
- `tests/` holds `regression/`, `features/`, and `benchmarks/`; new repros go to `tests/regression/` (the cluster tree under it is the structure).
- `examples/` has reference programs; `scripts/` hosts helpers; `zig-out/` holds build artifacts (ignore in git).
- Docs: `README.md`, `CONTRIBUTING.md`, and regression-local `README.md`/`BUG.md` files.

## Language Truth Hierarchy
- Treat runnable `.kz` tests under `tests/regression/` as the source of truth for Koru syntax and semantics.
- Treat prose docs as commentary on nearby executable examples, not as independent syntax authority.
- Before writing nontrivial Koru, inspect a passing regression test with the same shape.
- If no passing example exists for the syntax shape, say so and add or request a minimal repro instead of inventing syntax.

## A claim from another session is not ground truth
Package and test headers (`draw_per_entity.k`, `bounce.k`, `boids.k`, …) record a measurement **at write time** — and so does any artifact from another session: a scan, an architecture review, a report. It measured a tree at a moment that has since moved; 2026-08-31, a review listed `src/*.bak` files a purge commit deleted hours later — true at write time, false within a day. Treat every such claim as **unmeasured** until you have checked it against the current tree **this session** — and against the right clock: “live” includes the backend graph (`koru_std/compiler.kz`, `koru_std/build.zig`), not just `zig build`'s `exe.root_module` (see `frag-zig-build-does-not-compile-all-of-src`). Cite the tree, not the report. When you produce a scan or review, pin the tree you measured (`git rev-parse HEAD` + branch) at the top, or staleness is invisible.

Before you spend a session on a claimed gap — from a header, a review, or another session — check the claim **in this session**, against the current tree. Three claims, pick one, first sentence:

- **blocker** — you compiled it; it refused (quote the diagnostic).
- **not a blocker** — you compiled it, or a passing test *is* that join.
- **unmeasured** — you have not compiled it this session. Stop talking.

Do not weld pins + stale comments + “when it goes green” into a wall Lars cannot parse.

**Stores vs grids.** `std/store` has capacity, `insert`, and `take`. A grid cannot add or remove a row. Entities that come and go belong in a store. Do not invent a fixed pool of dead slots, dummy writes, or a “conditional store” hole to occupy cells. That is a grid limitation narrated as a language gap.

**Watch is not query.** `std/store(name) ! field` is a standing watch: body transplanted to write sites; no ambient from the enclosing flow (`690_006`). `std/store:query(name)` / `stripe` is a chain step. A query body can take a **borrow**: bare `<state>` on a parameter (`f: *Frame<frame>`). Draw already takes that. Issue is `<state!>`, consume is `<!state>`. If the compiler drops the phantom on the qbody input, that is a defect to compile and fix in `src/` — not a reason to put the game on a grid.

**Answer the question.** “Do you understand X?” is yes or no. Do not look X up and lecture the spelling. Lead with a sentence that parses. Archaeology after, or not at all.

## Find It Before You Build It
- Before building a check, a wall, a helper, or a shared surface, **find out whether it already exists.** This is a precondition on every task, not a step in one.
- **A forgotten mechanism is indistinguishable from an absent one until someone counts** — and the count comes back describing a catastrophe the mechanism has been silently preventing. The negative-test corpus was measured as 75% rotten, twice, before the wall holding it at 223/227 was found at `regression_lib.sh:608`.
- **Count with the enforcer's own predicate, not your reading of the rule.** Enforcement accretes cases; the prose never widens with it. Find the code that enforces the rule and read its condition before you count anything against it.
- Measured 2026-07-31: five separate tasks that day were "build X" where X already existed in some form — a mirror wall (`prose_check` check D, green, 55 rows), a diagnostic-pin wall, a benchmark-marker handler honoured by one half of the toolchain and unknown to the other, and a type registry that correctly turned out not to be needed.
- When the thing does exist and is inadequate, **widen it rather than building a second one.** Two walls guarding the same rule differently is how they drift.
- Say what you found, including "nothing." A search that came back empty is a result worth reporting; it is what tells the next reader the gap is real.

## Metacircular Safety & Collaboration
- Assume self-hosting: validate against compiler sources and generated artifacts; avoid speculative changes without tests.
- Align intent with maintainers/users; prefer short design notes and repros over large diffs.
- For core semantics, add a minimal `.kz` plus a targeted Zig test.
- Use judgment: ask for confirmation before major semantic changes or scope pivots; otherwise proceed and summarize clearly.

## Project Status (Greenfield / Experimental)
- There are **no external clients** to break. Assume greenfield and experimental.
- Prioritize correctness and forward progress over backward compatibility.
- It is acceptable to make semantic cleanups and breaking changes when they improve honesty or clarity.

### Agent‑specific note (Codex)
- Treat these guidelines as hard constraints, not flexible defaults.
- For diagnostic requests such as “look at why tests fail”, default to read-only investigation: run the requested checks, inspect failures, and report root causes before editing.
- Do not run `zig fmt` or any broad formatter unless the user explicitly requests formatting in the current task.
- Do not mass-edit tests to match an assumed API. If tests appear stale, report the mismatch first.
- Ask before changing compiler core contracts or build wiring, especially `src/ast.zig`, `src/parser.zig`, `src/lexer.zig`, `src/flow_parser.zig`, or `build.zig`.
- If a fix appears to require touching more than three files, stop and present the scope before editing.

## Project Memory (prose)
- Optional: `prose context` for current goals, constraints, gotchas.
- Optional: `prose search "<query>"` for designs/decisions; `prose status` for freshness.
- Treat prose output as supplemental, historical context; prioritize running code/tests for truth.
- Use prose to avoid regressions and gather background, not as a blocker.

## Build, Test, and Development Commands
- `zig build` — compile the compiler; output `zig-out/bin/koruc`.
- `zig build test` — run Zig unit/integration tests in `build.zig`.
- `./run_regression.sh [range|--no-rebuild|--ignore-leaks|--run-units]` — full regression suite; snapshots in `test-results/`.
- `node scripts/generate-status.js --format=cli` or `npm run status` — report regression markers without a full run.
- `./zig-out/bin/koruc path/to/file.kz` — compile a Koru source file.

## Coding Style & Naming Conventions
- Follow standard Zig style (4-space indent, lowerCamelCase for funcs/vars, UpperCamel for types). Do not run `zig fmt` unless explicitly requested.
- Keep modules focused; prefer small helpers in `src/` over ad-hoc scripts.
- Tests: regression tests are directories under `tests/regression/`, each with `input.kz` + markers (`MUST_ERROR`/`EXPECT`/`expected_error`). The tree is the structure — read it.

## Testing Guidelines
- Add a failing regression test first, then fix; ensure it passes in `./run_regression.sh`.
- For new behavior, cover in `zig build test` (`src/*_test.zig`) plus a minimal `.kz`.
- Broken tests stay in `tests/broken/` with a note; remove only when fixed.
- Aspirational regression tests are allowed: add failing with a note/issue, flip to passing when implemented.

## Commit & Pull Request Guidelines
- Use short, imperative, lower-case commit subjects (e.g., `add honest interpreter benchmark`); add a body when needed.
- PRs should state what changed, why, how to reproduce/verify (commands), and link issues.
- Show test evidence (`zig build test`, `./run_regression.sh …`), note skips, and call out doc updates tied to tests.
- Follow `CONTRIBUTING.md` for the regression-first workflow and documentation truth hierarchy.

### Two commit hooks will reject you — plan the message before you write it
`.git/hooks/commit-msg` enforces a discipline that is not visible from the diff,
so a first commit in a fresh session usually bounces. Both sections go in the
commit message body:

- **`## World Model`** — every commit answers "did a belief about the system
  change here?" Either `Signal: <type> — <what flipped, against which prior
  belief>`, or an explicit `Signals: acknowledged-none`. Silence is rejected;
  "nothing to report" is a conscious declaration, not an omission.
- **`## Membrane`** — if a belief-class signal fired, the concept must be
  gardened **in the same commit**, never queued. Stage `concepts/frag-<id>.md`
  and declare `Action:` (`create` | `evolve` | `merge` | `split` | `correct`)
  plus `Concept:`, with `Occludes:` on evolve, `Parents:` on merge/split, and
  `Severs:` + `Reason:` on correct. Nothing belief-worthy → `Evolution:
  acknowledged-none`.

Concepts live in-repo under `concepts/` (109 of them at time of writing) — one
belief per file, prose body, stable opaque id. **Survey before you create**: the
belief you are about to write down usually already exists and wants `evolve`,
and the hard call is evolve-versus-correct (`correct` means "was NEVER right";
when unsure it is `evolve`). Read `skill://membrane` for the full discipline,
and write the belief — the ruling, the why, the open questions — never a prose
restatement of code, line numbers, or probe results the repo already holds.

`--no-verify` exists and is the wrong answer; the hook is the discipline.
