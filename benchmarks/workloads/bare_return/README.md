# bare_return

**Question:** does the `-> T` bare-return (single-payload event output) close the
tiny gap vs Rust that the old single-variant union form (`| name T`) left open?

The old form compiled a single-payload event output to a one-variant
`union(enum) { name: T }` — *constructed* at every return and *field-extracted*
at every bind. On a hot path that construct-then-extract dance is overhead LLVM
did not always elide. The `-> T` form emits the payload directly (`Output = T`,
`return value`, `const m = handler(...)`), so the union is structurally gone.

## The workload

A fold-resistant LCG (Knuth MMIX constants) threaded through a single-payload
event on the hot path. `driver`'s native loop fires the `step` effect N times;
each firing resumes with `mix(acc)`, where `mix` is a `-> u64` bare-return event:

```koru
~pub event mix { x: u64 } -> u64
~proc mix|zig { return x *% 6364136223846793005 +% 1442695040888963407; }
...
! step p -> mix(x: p)          // produce-is-the-call: resume with mix(p)
```

LCG mixing is irreducible, so neither koru nor the baselines can constant-fold
it (output differs per N — `result = 13621014012951058945` at N=1e9). The
dependent chain (each step needs the prior `acc`) defeats ILP, so all three run
at ~1 ns/iter — the natural floor for a serial multiply-add recurrence.

`koru` is the bare-return form. `zig` and `rust` are the same LCG loop written
by hand (no event machinery, no union) — the ideal floor.

## Result (Apple Silicon, ReleaseFast / opt-level 3, best of 5)

| N     | koru   | zig (ideal) | rust   |
|-------|--------|-------------|--------|
| 1e8   | 121 ms | 118 ms      | 118 ms |
| 1e9   | 977 ms | 978 ms      | 977 ms |

**Dead heat.** Bare-return koru emits machine code identical in shape to
hand-written Zig — the union-elimination closed the gap completely.

## Why (the emitted code)

```
            OLD  | out u64                          NEW  -> u64
Output      union(enum) { out: u64 }                u64
return      return .{ .out = x *% C1 +% C2 };       return x *% C1 +% C2;
bind        const m = result_0.out;                 const m = handler(...);   // plain u64
```

The per-iteration construct+extract is gone. The only `union(enum)` left in the
emitted hot path is `driver`'s own multi-branch Output (`! step` + `| done`),
constructed **once** after the loop — off the hot path.

## Build / run

```bash
# koru
cd koru && koruc input.kz -o backend.zig && zig build -Doptimize=ReleaseFast && ./zig-out/bin/backend
./koru/a.out 1000000000
# zig
cd zig && zig build-exe bench.zig -O ReleaseFast -femit-bin=bench && ./bench 1000000000
# rust
cd rust && cargo build --release && ./target/release/bench 1000000000
```

(`koru_old` — the union-form twin — is intentionally absent: a faithful hot-loop
twin requires the deprecated `|>`-resume-after-chain form, which the language no
longer supports. The old emitted shape is shown in the table above instead.)
