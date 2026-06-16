# Contributing to Koru

**Tests are the spec.** What is legal — and what is rejected — lives in
`tests/regression/`, never in prose. There is no separate `SPEC.md` / `KORU.md`
/ `STATUS.md`; that is by design (see Challenge 003, "documentation without
prose": every falsifiable claim must be carried by a test, not a sentence).

Start here:

- **Operating doctrine** — `CLAUDE.md` (repo root) and the global one it inherits.
- **Toolchain orientation** — `skills/koru-toolchain/SKILL.md`.
- **Learn the language** — `koru-by-example.md`, `koru-tutorial.md` (both generated from passing tests).

Workflow:

1. **Pin the behavior as a test first.** A new feature or a bug both start as a
   test under `tests/regression/<CLUSTER>/<NNN_descriptive_name>/` — either
   `MUST_RUN` + `expected.txt`, or `MUST_FAIL` + `EXPECT` + `expected_error.txt`.
2. **Then make it green** (or pin it red if it's a known gap).
3. **Run the suite:** `./run_regression.sh --cache --parallel 8`.
