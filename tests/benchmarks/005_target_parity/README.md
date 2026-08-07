# 005_target_parity — the same source on both backends

One Koru program, compiled to Zig and to JavaScript, against a hand-written
JavaScript control. It exists because "Koru compiles to JavaScript now" is a
claim about semantics that the regression suite already pins, and a claim about
**cost** that nothing did.

## What it measures, and what it deliberately does not

The interesting comparison is **koru→js against hand-written JavaScript**. That
is a bound: emitted code cannot beat the loop a person would write over the same
data, so how close it gets is the whole result.

Zig is in the table for scale, not as an opponent. "Native is faster than
JavaScript" needs no benchmark; what needs one is whether the gap to Zig is
*JavaScript* or *us*.

The control uses four flat arrays because that is what Koru's store cell
actually emits — four column arrays plus a scalar `len`. The layouts are
identical, so the comparison isolates the **lowering** and not the data
structure.

## Measured

4096 entities, 50 000 frames, `pos += vel` as a two-column `stored` block in a
sweep arm, then one aggregate sweep. Apple M2 Pro, node 26.

| arm | time |
|---|---:|
| koru → zig | 0.08 s |
| koru → js | **0.30 s** |
| hand-written js | 0.29 s |

The emitted JavaScript is at the control. What separates it from Zig is
JavaScript.

For scale against the same program earlier the same day: it started at **2.78 s**
and fell to 0.30 s across two changes, neither of them in the JavaScript emitter
and neither of which moved the Zig arm at all.

- **A store nobody observes stops announcing.** A write announces its column so
  standing rules can react; with no rule attached, that announcement read the
  column back, allocated a branch object, tag-tested it against every column and
  discarded it — per write, per row. LLVM had erased the chain since the store
  was written. On node it was 77% of runtime. 4.3×.
- **The write unit monomorphises on its column set.** A `stored` block names its
  columns statically, so the mask one shared write unit tested at runtime is a
  compile-time constant at every site. 2.1×.

Both are visible in `koru→zig` as *nothing*, which is the point of having a
second backend at all.

## Correctness

All three arms print `checksum <n>` and `run.sh` compares them, failing non-zero
on a mismatch. A benchmark whose arms compute different things measures nothing,
and that failure is silent unless something checks — so the check is a positive
control, verified to fire by perturbing the control's accumulator (2026-08-07).

## The cast is not ceremony

`ecs_integration.k` writes `@as(i64, @intCast(i))` around the loop variable
because `for` yields a `usize` and `px` is `i64`, which Zig refuses — `010_064`
pins that gap. JavaScript has one number type and takes the loop variable bare.

So this program **compiled to JavaScript before it compiled to Zig**, and the
cast is what makes one source serve both. Worth remembering when "write once,
run on both targets" comes up: it currently has a direction, and it is not the
one anybody expects.

## Run

```sh
sh run.sh
```

Needs `zig build` first (for `koruc`) and `node` on PATH. Roughly 25 s, most of
it the two compiles.
