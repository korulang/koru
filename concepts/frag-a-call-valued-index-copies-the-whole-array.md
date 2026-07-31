---
type: belief
id: frag-a-call-valued-index-copies-the-whole-array
provenance: a 10k-row sweep spent ~100% of its runtime in _platform_memmove, moving 1.6 GB per pass, because the emitted read named a by-value column before computing a call-valued index
ts: 2026-07-31
---

# Naming a by-value aggregate before a call-valued index copies the aggregate (belief)

An emitter that produces

```zig
store.px[store.__koru_resolve(h)]
```

has not written an indexed load. It has written *materialise `store.px`, then
index it* — because `px` is a fixed-size array held **by value** in a mutable
global, and the index is a call that could modify that same global. The
evaluation order is forced, so the whole column is copied first.

At capacity 10,000 f64 that is 80,000 bytes per access. The sweep read did it
twice per row: ~1.6 GB moved per pass, and `sample` attributed ~100% of runtime
to `_platform_memmove`.

The fix is not clever. Bind the index first:

```zig
const r = store.__koru_resolve(h);
store.px[r] ...
```

## Why this hid

The store's own apply path had always hoisted — `const __koru_r = …resolve(row);`
then `px[__koru_r] = value` — so the write half was immune and the read half was
not, in the same file, on the same store. Nothing in the corpus compared them:
correctness tests pass identically either way, and no store test ran enough rows
for the copy to be visible as anything but a slightly slow test.

It took a borrowed workload with 10,000 rows to make an 80 KB copy expensive
enough to notice. See `frag-a-corpus-exercises-its-authors-idioms`.

## The methodological half — this is the sharper part

The finding was first written up as *the handle round-trip blocks
auto-vectorization*: three resolves per row, each a dependent load chain,
each carrying panic branches. That story was coherent, matched the emitted
source, and was **wrong about the cost by three orders of magnitude**. It was
also nearly un-falsifiable by reading, because everything it described was
genuinely there.

Reading emitted source tells you **what you asked the backend for**. It does not
tell you what the machine spends its time on, and the gap between those two is
not a constant factor. `sample` plus a disassembly answered in minutes what
staring at the emit could not have answered at all.

- **A perf claim derived from reading is a hypothesis.** Say so, and say what
  would refute it, before anyone builds a plan on it.
- **The refutation can be a ratio, not a number.** Hand-edit the emitted output,
  change exactly one thing, re-run both under the same conditions. A 1750×
  difference survives a machine under load average 51, where no absolute figure
  would have been worth recording.
- **Suspect asymmetry inside one emitter first.** Two paths that do the same job
  where one hoists and one does not is a stronger lead than any reasoning about
  what an optimiser might manage.

## Answered — the shape appears at nine more sites

The mechanical check was built (`invariants/checks/check_call_valued_index.py`,
wired as the `call-valued-index` citizen of `std/invariants`) and run over the
emitted-string content of `koru_std/*.kz` at `a2d4411a`: **nine live sites, all
in store.kz**, every one `__koru_resolve` in index position against a store
column — the query-projection read (1574 address-of variant, 1576 load), the
cycle-guard ancestor walk in all four write paths (2297/2494/2648/2860, one
resolve-indexed `parent` read per ancestor step, inside the walk loop), and
three cross-store/env row-reference rewrites (4846/5115/5337). The corpus had
seen none of them, as predicted: all correct, none hot in any test.

## Open

Whether the address-of variant (`&store.f[resolve(q)]`, site 1574) pays the
copy at all — it is a pointer computation, not a load, and has not been
measured. The check flags it anyway; the hoist is correct and at worst neutral.
