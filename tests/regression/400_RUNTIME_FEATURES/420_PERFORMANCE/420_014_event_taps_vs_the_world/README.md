# Test 2010: Event Taps vs The World

> What if observation had zero runtime cost?

---

## What This Tests

**Scenario**: Producer emits 10 million events, observer accumulates, validates on completion.

**The Pattern Everyone Uses**:
```
Producer → emit("next", value) → Observer accumulates
Producer → emit("done") → Observer validates checksum
```

**Implementations**:
- **Node.js**: `EventEmitter` - the canonical JS event system
- **Go**: Callback slices - idiomatic Go pattern
- **Rust**: `Vec<Box<dyn Fn>>` - simple callback vector
- **C**: Function pointer arrays - bare minimum overhead
- **Koru**: Event taps - compile-time AST rewrite

**The Question**: How much faster is compile-time observation vs runtime event emission?

---

## Why This Matters

**Event emission is EVERYWHERE:**
- Logging
- Metrics collection
- Tracing/observability
- State change notifications
- Pub/sub patterns

**But people avoid it because it's "slow":**
- Subscriber list management
- Iteration over listeners
- Virtual dispatch / function pointers
- Memory allocation
- Type erasure / boxing

**Koru taps change the equation:**
- No subscriber lists (compile-time)
- No iteration (fused with producer)
- No dispatch overhead (direct calls)
- No allocation (stack only)
- Full type information preserved

---

## The Key Insight

Traditional event emission:
```
emit("next", value)
  → lookup subscribers (runtime)
  → iterate list (runtime)
  → call each handler (indirect)
```

Koru taps:
```
~tap(count -> *) | next v |> accumulate(value: v.value)
  → AST rewrite at compile time
  → handler code fused into producer
  → direct call, no indirection
```

**The tap doesn't just disappear - it rewrites the AST.** It participates in ALL optimization passes: purity checking, constant folding, dead code elimination, fusion.

---

## Benchmark Details

### Node.js (`baseline_node.js`)
```javascript
const emitter = new EventEmitter();
emitter.on('next', (value) => { sum += value; });
emitter.on('done', () => { validate(); });

for (let i = 0; i < 10_000_000; i++) {
    emitter.emit('next', i);
}
emitter.emit('done');
```
**Overhead**: Subscriber map lookup, array iteration, function calls

### Go (`baseline_callbacks.go`)
```go
emitter.OnNext(func(value uint64) { sum += value })
emitter.OnDone(func() { validate() })

for i := 0; i < 10_000_000; i++ {
    emitter.EmitNext(i)
}
emitter.EmitDone()
```
**Overhead**: Slice iteration, function pointer calls

### Rust (`baseline_callbacks.rs`)
```rust
emitter.on_next(Box::new(|value| { sum += value; }));
emitter.on_done(Box::new(|| { validate(); }));

for i in 0..10_000_000 {
    emitter.emit_next(i);
}
emitter.emit_done();
```
**Overhead**: Vec iteration, boxed closure calls, RefCell borrow

### C (`baseline_callbacks.c`)
```c
emitter_on_next(&emitter, accumulate);
emitter_on_done(&emitter, validate);

for (uint64_t i = 0; i < 10000000; i++) {
    emitter_emit_next(&emitter, i);
}
emitter_emit_done(&emitter);
```
**Overhead**: Array iteration, function pointer calls (minimal!)

### Koru (`input_taps.kz`)
```koru
~event count { i: u64 } | next { value: u64 } | done {}

// TAP: Observe count, accumulate on "next"
~tap(count -> *) | next v |> accumulate(value: v.value)

// TAP: Observe count completion, validate
~tap(count -> *) | done |> validate()

~start() | ready |> #loop count(i: 0)
    | next n |> @loop(i: n.value + 1)
    | done |> _
```
**Overhead**: ZERO. Tap is compiled away, handler fused with producer.

---

## Running The Benchmark

### Manual
```bash
cd tests/regression/2000_PERFORMANCE/2010_event_taps_vs_the_world
bash benchmark.sh
```

### View Results
```bash
cat results.json | jq '.results[] | {command, mean, stddev}'
```

---

## Expected Results

Based on test 2004 (rings vs channels), Koru taps ran in **8.7ms** vs Vyukov MPMC at 80.9ms.

Event emitter libraries have MORE overhead than lock-free rings (subscriber management, iteration, dispatch). So we expect:

| Implementation | Expected Range | Reasoning |
|----------------|----------------|-----------|
| Node.js | 500ms - 2s | Interpreted, GC, map lookups |
| Go | 50ms - 150ms | Compiled but with slice iteration |
| Rust | 30ms - 100ms | Compiled, boxed closures |
| C | 20ms - 50ms | Bare metal function pointers |
| **Koru** | **~9ms** | Zero overhead, fused code |

**Hypothesis**: Koru taps will be 5-100x faster than traditional event emission.

---

## The Bigger Picture

This test answers a fundamental question:

> "Can we afford observability everywhere?"

With traditional event emitters: **No.** The overhead adds up.

With Koru taps: **Yes. Always. Everywhere.**

Because the abstraction isn't hiding runtime cost - it's **eliminating** it through compile-time transformation.

---

## Related Tests

- **Test 2004**: Rings vs Channels - taps vs Vyukov MPMC, crossbeam, Go channels
- **Test 2003**: Zero-cost taps - proves taps compile to no overhead
- **Test 2002**: Zero-cost events - proves event dispatch has no overhead
- **Test 2001**: Zero-cost flows - proves flow composition has no overhead

---

## Credits

- **Node.js EventEmitter**: The Node.js Foundation
- **Benchmark Tool**: hyperfine by @sharkdp

---

**The abstraction IS the optimization.**
