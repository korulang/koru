# prime_sieve_drag_race

Koru's entry for Dave Plummer's software drag race (`PlummersSoftwareLLC/Primes`):
a Sieve of Eratosthenes over primes ≤ 1,000,000, self-timed for 5 seconds, emitting
the official result line. The flex is real: the marking is **compiler-generated**
(`std/field:mark-multiples` is a `[transform]` that emits a per-stride unrolled,
residue-specialized scalar marker with baked-immediate masks — the backend then
auto-vectorizes it). The sieve, the timing loop, and the pass count are all Koru; only the clock
read (`std/time:now`) is a Zig effect — how Koru does every effect.

## Entries (`koru/`)

- **`faithful.k`** — `faithful=yes`. Allocates a fresh field every pass
  (`std/field:new` + `free`), per the drag-race faithfulness rule (the sieve is
  re-created each iteration).
- **`reuse.k`** — `faithful=no`. Allocates the field once and `clear`s + re-marks it
  each pass (threads it through the `#L`/`@L` loop as a borrow param
  `*Field<std/field:field>`). Faster, but a different faithfulness category — compare
  only against other `faithful=no` entries.

Both emit `validated primes: 78498` on stderr, then the official line on stdout:
`korulang;<passes>;<seconds>;1;algorithm=base,faithful=<yes|no>,bits=1`.

## Where the submission actually landed

Submitted 2026-06-30 as `PlummersSoftwareLLC/Primes#1077`; **closed the same day,
not merged.** The maintainer closed it on *language eligibility* — the submission
prompted him to write that section of CONTRIBUTING, which now requires a mature
language with independent users, public documentation and non-benchmark usage —
and explicitly not on the sieve, the numbers, or good faith. He invited a future
resubmission once Koru has a public identity and users.

Four technical asks were listed as "would still need fixing anyway":

1. Pin the toolchain to an immutable full commit SHA, not a movable tag.
2. Remove the hidden/bidirectional Unicode characters GitHub flagged.
3. Reconsider `faithful=yes` — the stack placement fires only for a
   compile-time-constant sieve size, and the rules want a runtime-sized
   allocation. **This is the only one that is real work**: a runtime-sized
   field that is still allocation-free.
4. Show generated-code excerpts proving `mark-multiples` is a general transform
   and not benchmark-specific backend logic.

Nothing here is pending review. Treat the entries as our own benchmark until
that eligibility bar is met.

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
