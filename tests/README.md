# Koru tests

Full orientation — structure, markers, how to run, the four metacircular
stages — lives in `skills/koru-toolchain/SKILL.md`. This file is just the map.

- **`regression/`** — the suite. Each test is `<CLUSTER>/<NNN_name>/` with marker
  files. A passing `.kz` is law; a `MUST_FAIL` test + its `expected_error` is law
  about what is *rejected*.
- **`benchmarks/`** — performance workloads (see `benchmarks/README.md`).

Run:

```bash
./run_regression.sh --cache --parallel 8   # full suite, cached
./run_regression.sh 330_016                # single test
./run_regression.sh --status               # snapshot
```
