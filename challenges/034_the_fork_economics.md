---
challenge: fork-economics
kind: frame
status: standing
yields: koru-par matches or beats bend-par on the Osprey irregular-recursion cells — fib ≤ 29.23ms and coins ≤ 33.2ms on arm64 ReleaseFast — with a parity guarantee that [parallel] can never be slower than the same kernel sequential
catalog: none — convergent, measured target
family: performance
created: 2026-11-23
---

*Walker context — measured 2026-11-23, tree `koru @ 3b837c2ed`,
`koru-benchmarks` osprey-compute-kernels `results/latest.json` (2026-10-25
board) plus fresh ReleaseFast timings this session.*

*The board: Koru wins or ties 20/22 Osprey kernels sequentially and 10/12
parallel cells, usually by 5–100x. The only losses are the two
irregular-tree-recursion kernels:*

*| kernel | koru-seq | koru-par | bend | bend-par |*
*|---|---|---|---|---|*
*| fib(35) | 27.27 | 38.77 | 68.47 | **29.23** |*
*| coins(600,5) | ~86.5 | ~68.4 mean (37–122 range) | 67.88 | **33.2** |*

*koru-par fib is 42% SLOWER than koru-seq fib — the annotation is a net loss
on fine-grained recursion. koru-par coins port exists
(`suites/osprey-compute-kernels/koru-par/coins/coins.k`, oracle-green
116727, uncommitted) and shows the same shape: 1.26x mean speedup with
straggler variance.*

*Root cause, verified in emitted code: every `[parallel]`-marked call emits
per-invocation fork machinery — `Input` struct, `WaitGroup`, TLS
`__koru_par_depth` read, atomic `__koru_par_tasks` load, spawn-or-inline
branch, join drain at first read (`src/emitter_helpers.zig:9991-10050`,
pool prelude `:1500-1520`). `DEPTH_CAP=7` (`:1513`) means only ~255 nodes in
a fib/coins tree can ever fork; the other ~30–50 million calls pay the
check to run inline. Bend-par wins because HVM reduction parallelizes for
free — but the fix is not Bend's runtime. It is Koru's own analysis:
the compiler can estimate recursive-subtree size from the arguments and
emit fork-only-when-it-pays.*

*This is existential for the project — the user has ruled that if Koru
cannot match Bend on this board, the project ends. Treat the bar as real.*

---

## The brief (sealed — you are the contestant)

**Make `[parallel]` economically honest on self-recursive tors: fork only
when the subtree is big enough to amortize the fork, and never pay parallel
machinery on calls that cannot fork.**

Two measured defects to close, in order of leverage:

1. **The inline path is priced like the fork path.** Today every marked
   call builds the slot, the `WaitGroup`, the input struct, and the
   depth/tasks checks even when `DEPTH_CAP`/`CAP` forces inline execution.
   Restructure emission so a call that cannot fork pays a plain call —
   no waitgroup, no atomic, no pending_parallel bookkeeping. This alone
   should erase most of the 42% fib-par deficit.
2. **The fork decision is structural, not economic.** `depth < 7` forks a
   `fib(3)` subtree as readily as `fib(30)`. For self-recursive tors the
   compiler can estimate subtree work from the arguments (fib's tree is
   ~φⁿ; ways' depth is bounded by `amount`). Emit a size guard: above the
   threshold, fork; below, plain call. The threshold is a compile-time
   constant derived from the measured fork cost — not a tuning knob.

## Constraints

- **Parity is the invariant, not the goal.** After your change,
  `koru-par` must never be slower than `koru-seq` on the same kernel —
  on ANY kernel, including ones you didn't touch. If you cannot prove
  that, you have not finished.
- **Oracle-green.** `fib` → 9227465, `coins` → 116727, and every other
  `[parallel]` regression pin stays green. Run the affected tests plus
  controls; the full board is for publishing, not iterating.
- **`DEPTH_CAP = 7` is a frag ruling** — "landed as semantics, not a
  tuning knob" (`emitter_helpers.zig:1508`). You may not change its
  value. You may add guards around it.
- **No new syntax.** `[parallel]` keeps its spelling and meaning. If your
  fix needs a spelling, stop — that is a ruling for Lars, not a contestant.
- The worklist/reduction answer is explicitly OUT of scope — this is
  analysis reaching into emission, not a new runtime.

## Done-gates (self-checkable)

- `koru-par/fib` ≤ **29.23ms** and `koru-par/coins` ≤ **33.2ms**,
  arm64 ReleaseFast, hyperfine warmup 3 min-runs 10, on this machine.
  Report the noise honestly — a straddling result is REFUSED, not passed.
- `koru-par` ≥ `koru-seq` speed on every measured kernel (parity table
  in your report, not a claim).
- Both oracles green; `zig build test` green; affected regression tests
  green with pins for whatever mechanism landed.
- The mechanism is described in the commit: what the compiler now proves
  about the recursion, what it emits differently, what it costs.

## What this is not

- Not a benchmark-hacking exercise. The ports are faithful naive
  algorithms; the win must come from the compiler, not the source.
- Not permission to weaken `[parallel]`'s contract for coarse work —
  the for-loop partition path (`koru_std/control.for.kz`) and the
  kernel path (`koru_std/kernel.kz`) must not regress.
- Not a request to match Bend everywhere — only these two cells. The
  rest of the board is already won; do not spend the session there.

## Replay log — 2026-11-23 (continued)

Landed and committed:
- `076bfc28c` — spawned-flag drains + probe/permit task check (~20-25% on both par kernels)
- `217011a31` — self-recursive work-size guard: marked calls resolving to their
  own event fork only while an integer input field >= `__koru_par_SIZE_FLOOR` (28)

Measured (ReleaseFast, oracle-green):
- fib-par: 41.2 -> **19.8ms** — BEATS bend-par 29.23 by 32%
- coins-par: ~55ms vs bend-par 33.2 — still behind

Decomposition proven by emitted-Zig variants: fork count irrelevant
(DEPTH_CAP 4-10 flat, live-CAP 24/48 collapse), per-call scaffolding free,
the cost was waitAndWork on never-spawned wgs + the shared atomic, then
task granularity. SIZE_FLOOR=28 is a ruling constant, not yet derived.

Remaining cell: coins-par. Its tree is skewed (amount-c vs kind-1
subtrees differ by orders of magnitude); ~128 coarse fork-join tasks leave
a straggler tail no depth/cap/size guard removes. bend-par wins via HVM
node-granular work stealing — work items are graph reductions stolen
continuously, self-balancing by construction.

Next rung (the "compile to that idea" escalation, now with fib as proof
the compiler-side version works): lower provably-pure self-recursive tors
to an explicit worklist — each self-call pushes (state,args), each return
pops; workers steal items from a shared deque. No spawnWg per call (~ns
push vs ~µs spawn), no depth cap, self-balancing on skewed trees.
Gates: purity_analyzer must prove the tor pure; sequential path must stay
native calls (parity invariant); coins-par <= 33.2ms, fib-par must not
regress below 19.8ms.
