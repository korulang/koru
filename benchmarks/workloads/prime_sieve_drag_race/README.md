# prime_sieve_drag_race

Koru's entry for Dave Plummer's software drag race (`PlummersSoftwareLLC/Primes`):
a Sieve of Eratosthenes over primes ≤ 1,000,000, self-timed for 5 seconds, emitting
the official result line. The flex is real: the marking is **compiler-generated**
(`std/field:mark-multiples` is a `[transform]` that emits a per-stride unrolled SIMD
marker). The sieve, the timing loop, and the pass count are all Koru; only the clock
read (`std/time:now`) is a Zig effect — how Koru does every effect.

## Entries (`koru/`)

- **`faithful.k`** — `faithful=yes`. Allocates a fresh field every pass
  (`std/field:new` + `free`), per the drag-race faithfulness rule (the sieve is
  re-created each iteration).
- **`reuse.k`** — `faithful=no`. Allocates the field once and `clear`s + re-marks it
  each pass (threads it through the `#L`/`@L` loop as a borrow param
  `*Field<std/field:field>`). Faster, but a different faithfulness category — compare
  only against other `faithful=no` entries.

Both print `validated primes: 78498` then the official line
`koru;<passes>;<seconds>;1;algorithm=base,faithful=<yes|no>,bits=1`.

## Run

```
zig build                                     # build koruc
mkdir /tmp/run && cp koru/faithful.k /tmp/run # koruc clobbers CWD — never run in repo root
cd /tmp/run && <repo>/zig-out/bin/koruc faithful.k && ./a.out
```

## Deterministic twins (in the regression suite)

The timed entries are non-deterministic (pass count varies), so they are NOT
regression tests. The fixed-count twins are pinned under
`tests/regression/900_EXAMPLES_SHOWCASE/910_LANGUAGE_SHOOTOUT/`:
`2111_prime_sieve_timed_loop` (faithful shape) and `2112_prime_sieve_reuse_loop`
(reuse shape).

## Perf work

The mission brief for squeezing more performance (bottleneck = per-pass allocation;
the 3-way Linux rival bench; the dead-ends already explored) lives at
`docs/drag_race_perf_brief.md`. The submission scaffolding plan is at
`docs/drag_race_submission_plan.md`.
