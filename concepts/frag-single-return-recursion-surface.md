---
type: belief
id: frag-single-return-recursion-surface
provenance: introduced by 095cb43f — test(pin): multi-bind produce + nested-if-arm produce — the tree-recursion shapes (320_124/125)
ts: 2026-07-04
---

# Single-return recursion surface — tree recursion is already expressible (belief)

The single-return form (`-> T` bare-return events with `:` call-site binds)
composes through **every naive recursion shape** in the Osprey compute-kernel
corpus, with zero compiler changes. Proven 2026-07-04 by the koru-benchmarks
port frontier going 6/22 → 12/22 in one session, every port green on its
first grounded attempt:

- **Multi-arg tail self-recursion** with an accumulator (powmod), riding the
  320_121/320_122 parallel-assignment staging.
- **Non-tail single recursion** where the produce transforms the result after
  the call (digitsum, collatz).
- **Three-way branches** inside a single-return event, spelled as nested
  `| else |> if(...)` with `->` produces from the NESTED arms (collatz,
  primes) — pinned 320_125.
- **Non-tail TREE recursion**: a produce reading TWO chained binds
  (`fib(n: n - 1): a |> fib(n: n - 2): b -> a + b`) — pinned 320_124; an
  inner recursive result feeding an outer recursive call's argument (hanoi);
  and THREE recursive binds feeding a fourth recursive call, produced from
  the then-arm (tak).

The prior belief — carried on the koru-benchmarks baton as the "port
frontier" open question, "can pure Koru inline/combine recursive
value-event calls?" — projected fib/hanoi/tak as probable feature gaps.
They are not. **Expressiveness of naive recursion is closed.** Performance
parity is a separate, per-kernel, measured question — and its first concrete
resolution landed here: the non-flattening paths (tak's inner tree-recursion,
any value event reached through real `.handler(.{…})` dispatch) were slow not
from dispatch cost per se but from an **argument-ABI hole**. A value event
whose Input exceeds the AArch64 16-byte register threshold (tak's 3×i64) was
lowered as `handler(Input)` and passed BY POINTER, so every call marshalled
args through the stack where C passes them in registers; the gap scaled with
field count (2-field ack/coins already register-passed, already at parity).
Register-passing via an `inline` handler shim over a scalar-param impl closes
it (tak → C parity on a quiet box; see koru-benchmarks `tak` and the emitter's
`isScalarValueFields` shim). Still open: parity on kernels whose Inputs aren't
all-scalar (they keep the struct ABI), the ackermann/coins anomaly where GHC
beats even `-O2` C (unexplained, possibly not faithful), and the genuinely
absent surfaces the remaining kernels name (recursive ADTs, persistent lists,
string-map folds, string builtins).
