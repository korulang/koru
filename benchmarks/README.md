# Effect-Branch Benchmark Suite

Cross-language measurement of yield/generator/effect-branch behaviour. Companion to the blog post **Effect Branches: Beyond Yield**.

## Discipline

- Don't fudge results. When the optimizer folds, report it. When a language can't do a test natively, mark it `emulated` with the implementation note attached.
- Each test answers a question. The question is in the workload's `README.md`.
- Same input → same output. Mismatched output across languages is a finding.
- Five runs per (workload, language, n), report median + min/max.

## Layout

- `workloads/<name>/<language>/` — implementations
- `workloads/<name>/README.md` — what question this test answers
- `scripts/` — build + run helpers
- `results/` — append-only CSV per workload
- `CAPABILITIES.md` — language × feature grid (what's native, what's emulated, what's impossible)
- `ENV.md` — machine + tool versions (reproducibility)

## Status

In flight — see `STATUS.md` for what landed and what's parked.
