# Test 2011: Multicast Scaling

> How does performance scale with observer count?

---

## What This Tests

**Scenario**: Producer emits 10 million events to N observers, each accumulating values.

**The Question**: Do callbacks scale O(n) while taps scale O(work)?

**Implementations**:
- **C**: Function pointer arrays with 1, 5, 10 handlers (bare minimum callback overhead)
- **Koru**: Event taps with 1, 5, 10 taps (compile-time AST fusion)

---

## Results

| Observers | C (callbacks) | Koru (taps) | Koru advantage |
|-----------|---------------|-------------|----------------|
| 1 | 24.3 ms | 8.2 ms | **3.0x faster** |
| 5 | 34.6 ms | 8.7 ms | **4.0x faster** |
| 10 | 64.3 ms | 11.6 ms | **5.5x faster** |

**Scaling:**
- C: 1→10 handlers = +165% time
- Koru: 1→10 taps = +41% time

**The more observers you need, the bigger Koru's advantage.**

---

## Why This Matters

### Callbacks: O(n) Dispatch Overhead

Each callback requires:
1. Load function pointer from memory
2. Indirect jump
3. Do work
4. Return

With 10 handlers × 10M events = **100 million indirect calls**.

### Taps: O(work) Only

Taps are fused at compile time. No dispatch loop, no function pointers.

10 taps = 10 inline additions per iteration. Zero dispatch overhead.

---

## The Implication

**Traditional observability trade-off:**
- More observers = slower hot path
- Teams limit logging/metrics/tracing to reduce overhead

**With taps:**
- More taps = more work, but no dispatch overhead
- Observe everything, everywhere, always

---

## Running The Benchmark

```bash
cd tests/regression/2000_PERFORMANCE/2011_multicast_scaling
bash benchmark.sh
```

---

## Files

- `baseline_c_1.c` / `baseline_c_5.c` / `baseline_c_10.c` - C function pointer baselines
- `input_taps_1.kz` / `input_taps_5.kz` / `input_taps_10.kz` - Koru tap implementations
- `benchmark.sh` - Build and benchmark script

---

## Related

- **Test 2010**: Event Taps vs The World (absolute performance)
- **Test 2004**: Rings vs Channels (taps vs MPMC)

---

**The abstraction IS the optimization. And it scales.**
