# Test 2012: Conditional Taps

> What if the condition WAS the dispatch?

---

## What This Tests

**Scenario**: 10M events, 10 conditional handlers. Each handler only cares about 1/10th of events.

**The Pattern**: Achievement systems, rule engines, event filtering - many handlers, sparse activation.

**Implementations**:
- **C**: Dispatch ALL handlers, each checks condition internally
- **Koru**: `when` clauses compile to direct branch checks

---

## Results

| Implementation | Time |
|----------------|------|
| C (conditional callbacks) | **103.3 ms** |
| Koru (when taps) | **10.3 ms** |

**10x faster.**

---

## Why This Happens

### Callbacks: Dispatch ALL, Check Inside

```c
for (int h = 0; h < 10; h++) {
    handlers[h](value);  // 100M function calls
    // Each handler: if (my_range) { work; } else { return; }
    // 90% of calls do nothing
}
```

### Taps: Condition IS the Dispatch

```koru
~tap(event -> *) | branch when (condition) |> handler()

// Compiles to:
if (condition) { handler(); }
// Just a branch. No dispatch if condition is false.
```

---

## The Insight

**Callbacks**: Pay for dispatch even when handler does nothing.

**Taps with `when`**: Skip handlers entirely when condition is false.

The more selective your handlers, the bigger the win:
- 10 handlers, 10% match rate → 10x faster
- 100 handlers, 1% match rate → potentially 100x faster

---

## Running

```bash
bash benchmark.sh
```

---

**The condition IS the dispatch.**
