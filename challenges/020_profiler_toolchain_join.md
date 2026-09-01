---
challenge: profiler-toolchain-join
kind: frame
status: standing
yields: one profiler × toolchain join closed — pin, fix in koru, oracle green
family: toolchain
---

# Challenge 020 — Profiler toolchain join

> Event taps + `[profile]import std/profiler` + `--profile` must survive real
> programs, not just `510_profiler_end_to_end`. Each run picks **one join**
> (profiler × store, profiler × comptime transform, profiler × import gate, …),
> measures it from the point of use, pins any refusal, fixes in `koru_std/` or
> `src/` — never routes the consumer around the defect.

Standing **frame**. The oracle is mechanical: `./scripts/bettermaker_profiler_oracle.sh`.

---

## The path (one join per pass)

1. **Name the join** — e.g. `profiler × plural store:new`, `profiler × nested loops`.
2. **Minimize** — smallest program that still stresses the join (regression dir or `examples/`).
3. **Measure** — compile with `--profile`, run binary, read `/tmp/koru_profile.json`.
4. **Pin** — new test under `360_TAPS_OBSERVERS/` or adjacent cluster; `COMPILER_FLAGS: --profile`; `post.sh` for trace shape when runtime flows exist.
5. **Fix** — in compiler/stdlib; void-branch tap continuations must not be read as store interceptors (see `511_profiler_plural_store`).
6. **Oracle** — `./scripts/bettermaker_profiler_oracle.sh` (controls + optional scale probe).

---

## Confidence gate

**Ship unattended** when:

- Filtered regression controls pass (`Running N tests` matches ask).
- New pin is green (if this pass added one).
- No `write-*` in trace for opaque profiler (post.sh pattern).

**Do not** report success from frontend compile alone — backend exec + trace or `MUST_RUN` output required.

---

## Control set (default oracle)

| Test | Guards |
|------|--------|
| `511_profiler_plural_store` | profiler + plural `store:new` + insert |
| `510_profiler_end_to_end` | `[profile]import` + Chrome trace |
| `420_003_profiler_loop` | nested label loops in trace |
| `690_121_twenty_six_component_stores` | large store program still green (no profile — sanity) |

---

## Known ceiling (not a failure)

Store CRUD lowers to direct handler calls — store ops may not appear as transition
bars. Runtime **flows** must appear in the trace; store silence is an emitter fact,
not a green-by-narration.

Playbook: `.claude/skills/bettermaker/koru-toolchain-join.md`
