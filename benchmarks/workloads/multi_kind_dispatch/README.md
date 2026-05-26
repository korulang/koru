# Workload: multi_kind_dispatch

## Question

When a producer fires TWO distinct effect kinds (tick on even i, tock on odd i) and the consumer handles each kind separately, what does each language do under the hood? Native multi-kind dispatch (Koru) is a direct call per kind. Single-kind generators have to flatten to a tagged union + switch in the consumer body. The question is the cost difference.

## Shape

- Input: `n` (runtime argv)
- Process: producer yields tick(i) when i%2==0, tock(i) when i%2==1
- Consumer counts ticks and tocks
- Output: `ticks = T tocks = K` to stdout (T = K = n/2 for even n)

## Native vs emulated

| Language | Implementation | Native multi-kind? |
|---|---|---|
| Koru | `! tick u64` + `! tock u64`, each with own handler | ✓ native |
| C# | yield `(int Kind, ulong Value)` tuple; consumer switches on Kind | ◐ emulated |
| Python | yield `('tick', v)` or `('tock', v)` tuple; consumer dispatches on string | ◐ emulated |
| JS | yield `['tick', v]` array; consumer dispatches | ◐ emulated |
| Rust | iterator over `enum Ev { Tick, Tock }`; fold matches on variant | ◐ emulated (zero-cost enum) |

Emulated rows: the implementation is the most idiomatic single-kind generator + switch dispatch shape for that language.

## Expected output

For n=1000000: `ticks = 500000 tocks = 500000`
