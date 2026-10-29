# 011_linq_task — the LINQ post's headline task, on .NET

"Effect Branches vs LINQ" raced Zig-emitted Koru against LINQ on .NET —
the honest objection to that table is that it compared a native binary
against a managed enumerator pipeline. This benchmark removes the
objection: it races the **cs-emitted** Koru program against LINQ on the
same runtime, same JIT, same machine.

The task is the post's literal headline shape — filter → map → sum:

```csharp
data.Where(x => x % 2 == 0).Select(x => x * 3L).Sum()
```

```k
run = for(1..(@as(usize, @intCast(n)) + 1))
    ! each i when i % 2 == 0 |> acc(v: @as(i64, @intCast(i)) * 3)
```

`when` on `! each` is `Where`; `* 3` is `Select`; `acc` is `Sum`.

## What `generated` actually is

Not a paste — `run.sh` compiles `task.k` with `--lang=cs`, builds the
resulting `output_emitted.cs` into the benchmark assembly, and the
harness calls `main_module.run_event.handler` — the method a real call
site invokes. If the emission shape changes, this file stops compiling.
That is the pin.

The emitted handler is the task fused: `total` is hoisted to a local,
the `when` guard emits as a plain `if` inside the `for`, the map and the
accumulate are two instructions inside it, and the cell writes back once
after the loop:

```csharp
var total = KoruHost.total;
for (long __koru_item2 = 1; __koru_item2 < ((long)((n)) + 1); __koru_item2++) {
    { var i = __koru_item2; if (i % 2 == 0) {
        var __koru_p_v = (long)((long)((i)) * 3);
        total += __koru_p_v;
    } } }
KoruHost.total = total;
```

## The accumulator is a real `capture` cell

`capture` now lowers on cs — the cell is a `ValueTuple` (named mutable
fields, inferred types), so `capture { total: 0[i64] }` /
`captured { total: … }` / `| captured res` all emit directly. `acc` is
`~proc acc|cs { total = v; }` — once, at `| captured res`, copying the
finished total out for the harness. Earlier revisions shimmed the
accumulator with a module static and disclosed it; that substitution is
gone.

## Comparator set (declared before running)

| arm | shape |
|---|---|
| `linq-array` | `data.Where().Select().Sum()` on a materialized `int[]` — LINQ's best case |
| `linq-range` | same pipeline over lazy `Enumerable.Range` — the true source-equivalent; `for` materializes nothing either |
| `yield` | a producer state machine feeding `Select`+`Sum` — the producer-side LINQ idiom |
| `foreach` | hand loop over the array — the post measured this BEATING LINQ, so racing only LINQ would rig the field |
| `direct` | fused handwritten loop over the range — the atom this task reduces to |

## Measured

N = 10M, min of 3 reps, .NET 8 on arm64, correctness control on every arm
(all sums = 75,000,015,000,000 — a stage that never ran fails the run):

| arm | ms | B/rep |
|---|---|---|
| `generated` | **7** | 40 |
| `linq-array` | 14 | 144 |
| `linq-range` | 31 | 200 |
| `yield` | 45 | 136 |
| `foreach` | 7 | 40 |
| `direct` | 7 | 40 |

Generated sits at the floor — identical to `foreach` and `direct` — and
beats LINQ's best case 2x on its own runtime. The lazy-source row is the
honest LINQ comparison (neither side materializes): 4.4x. `yield`, the
producer idiom the LINQ post's Rosetta stone maps to a tor, pays ~6.4x.

**The disassembly says how close.** `DOTNET_JitDisasm` on `direct`'s
Tier1-OSR hot loop is six instructions — `tbnz` (the parity test, taken
on odd), `mov`+`madd` (`i * 3` fused into `total +=`), `add`, `cmp`,
`ble`. The generated handler's OSR loop is the same six **plus one**:
`mov x3, x1` — the `i := __koru_item2` binding survives as a register
copy the JIT didn't coalesce (the guard tests the item register while
the `madd` consumes the copy). One register-register move per element at
10M elements is inside the noise — both arms measure 7ms — and the IL
itself is a plain local copy; the surviving `mov` is a JIT OSR regalloc
choice, not an emission defect. `blt` vs `ble` in the two loops is the
exclusive-vs-inclusive bound spelling — same trip count.

These numbers rhyme with the post's cross-runtime table (LINQ 12.0ms,
foreach 8.9ms, Koru ~6.0ms at N=10M) — measured on different hardware and
a different runtime, same ordering, same shape. On .NET the cs emission
holds the ordering without the native-binary caveat — and the loop bound
here is opaque (`n` arrives at runtime), so no fold is in play.
