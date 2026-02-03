# Repository Guidelines

## Project Structure & Module Organization
- `src/` is the metacircular compiler pipeline; wire passes in `build.zig` and trace dependencies.
- `lib/`, `libs/` for runtime/backends; `koru_std/` is the standard library (`KORU_STDLIB`).
- `tests/` holds integration, feature, regression, broken suites (see `tests/ORGANIZATION.md`); new repros go to `tests/regression/`.
- `examples/` has reference programs; `scripts/` hosts helpers; `zig-out/` holds build artifacts (ignore in git).
- Docs: `README.md`, `KORU_SYNTAX.md`, `CONTRIBUTING.md`.

## Metacircular Safety & Collaboration
- Assume self-hosting: validate against compiler sources and generated artifacts; avoid speculative changes without tests.
- Align intent with maintainers/users; prefer short design notes and repros over large diffs.
- For core semantics, add a minimal `.kz` plus a targeted Zig test.
- Use judgment: ask for confirmation before major semantic changes or scope pivots; otherwise proceed and summarize clearly.

### Agent‑specific note (Codex)
- This guidance is primarily to constrain Claude; Codex may operate with a lighter touch.
- Codex is authorized to proceed without extra confirmations for routine changes, clean generated artifacts proactively, and treat these guidelines as flexible defaults (not hard stops).

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
- Run `zig fmt` before committing; follow standard Zig style (4-space indent, lowerCamelCase for funcs/vars, UpperCamel for types).
- Keep modules focused; prefer small helpers in `src/` over ad-hoc scripts.
- Tests: integration files numbered `tests/integration/0N_*`, feature tests descriptive, regressions `tests/regression/bug_###.kz` or `issue_###.kz`.

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
