# Koru register — toolchain join (profiler / taps / flags)

Use when the pass bed is **compiler/stdlib** and the path is **observe → measure → pin → fix**.
Read `koru-toolchain` skill first for compile/run hygiene.

## One pass checklist

```
[ ] pgrep -fl "run_regression|zig build"     # empty before edit/build
[ ] Name the join (one sentence)
[ ] Minimize repro (input.k or input.kz + COMPILER_FLAGS if --profile)
[ ] ./scripts/bettermaker_profiler_oracle.sh   # before — expect red if hunting
[ ] Fix in koru_std/ or src/ — no consumer reroute
[ ] Add/adjust regression pin + post.sh if trace-shaped
[ ] ./scripts/bettermaker_profiler_oracle.sh   # after — must green
[ ] Commit with command output in body (bettermaker step 6)
```

## Mechanical oracle

```bash
./scripts/bettermaker_profiler_oracle.sh              # regression controls
./scripts/bettermaker_profiler_oracle.sh --scale      # controls + 10×10 loop probe
./scripts/bettermaker_profiler_oracle.sh --probe path.kz  # compile+run one candidate
```

Exit 0 = gate passed. Non-zero prints which gate failed.

Profiler controls run with `--parallel 1` — every pin shares `/tmp/koru_profile.json`.

## Default controls

`512_profiler_store_query` · `511_profiler_plural_store` · `513_profiler_multiline_conditional_import` · `514_profiler_comptime_event_taps` · `510_profiler_end_to_end` · `420_003_profiler_loop` · `690_121_twenty_six_component_stores` · `310_113_gated_import_inside_imported_module`

Always verify harness line: `Running N tests` equals the number of filters passed.

## Pin shape (profiler end-to-end)

```
tests/regression/.../NNN_name/
  input.k or input.kz
  COMPILER_FLAGS          # --profile
  MUST_RUN
  expected.txt
  post.sh                 # grep trace; reject write-* self-observation
```

Pure `.k` files: no `~` prefix. Proc bodies need `const std = @import("std");`.

Trace event names use dots: `"std.io:print.ln"`, not slashes.

## Manual scale probe (optional)

`examples/profiler_scale.kz` — 10×10 nested loops. Expect ~101 transition bars,
0 profiler self-observation, closed JSON. Requires two-step run:

```bash
koruc examples/profiler_scale.kz -o /tmp/backend.zig --profile   # repo root
cd /tmp && zig build && ./zig-out/bin/backend output && ./output
```

## Frame shelf

`challenges/020_profiler_toolchain_join.md` — pick the next join when this register feels stale.
