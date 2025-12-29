# Test 2004: Concurrent Message Passing - Multi-Language Comparison

> Can lock-free concurrency primitives compete across Go, Zig, Rust, and Koru?

---

## What This Tests

**Scenario**: Producer/consumer ping-pong with 10 million messages

**Implementations** (fair apples-to-apples comparison):
- **Go**: Buffered channels + 1 goroutine (producer), main does consumer
- **Zig**: MPMC ring + 1 thread (producer), main does consumer (raw loop)
- **Rust**: Crossbeam channels + 1 thread (producer), main does consumer
- **Koru**: MPMC ring + 1 thread (producer), main does consumer (`#loop/@loop`)

**Success Criteria**:
1. All zero-runtime approaches (Zig, Rust) should be competitive with Go's runtime
2. **Koru should match Zig** (proving event abstractions are zero-cost)

**What Makes This Fair**:
- All use same threading model: 1 spawned thread + main thread does work
- Eliminates thread spawn overhead differences
- **Koru's test**: Does `#loop/@loop` event-driven code on main thread compile to the same performance as raw Zig loops?

---

## Why This Matters

This benchmark proves whether Koru's concurrency story (events + MPMC rings) can compete with established languages.

**The Story**:
- **Go channels**: Battle-tested, runtime-optimized, idiomatic Go
- **Zig MPMC**: Pure userspace, no runtime, just atomics
- **Rust crossbeam**: Zero-cost abstractions, lock-free channels
- **Koru**: High-level events/flows compiling to Zig-level performance

**What we're proving**:
- Can zero-runtime concurrency (Zig/Rust) compete with Go's runtime?
- Can Koru's high-level abstractions match low-level Zig/Rust performance?
- Are Koru's events truly zero-cost?

---

## Benchmark Details

### Go Baseline (`baseline.go`)
```go
messages := make(chan uint64, 1024)  // Buffered channel
go producer()  // Send 10M messages
go consumer()  // Receive and sum
wg.Wait()      // Synchronize
```

**What's tested**: Go's channel runtime, goroutine scheduler, synchronization

### Zig Baseline (`baseline.zig`)
```zig
var ring = MpmcRing(u64, 1024).init();
const producer = try std.Thread.spawn(...);
const consumer = try std.Thread.spawn(...);
producer.join(); consumer.join();
```

**What's tested**: Lock-free MPMC ring, pure atomics, no runtime overhead

### Rust Baseline (`baseline.rs`)
```rust
let (tx, rx) = bounded(1024);  // Crossbeam bounded channel
let producer = thread::spawn(move || ...);
let consumer = thread::spawn(move || ...);
producer.join(); consumer.join();
```

**What's tested**: Crossbeam lock-free channels, zero-cost abstractions, no async runtime

### Koru (`input.kz`)
```koru
~ring.enqueue(value: i)
| ok |> _
| ?full |> _  // Optional - drop on overflow
```

**What's tested**: Event-based concurrency, zero-cost abstraction, optional branches

---

## Expected Results

### Hypothesis 1: Zero-runtime approaches compete with Go
**Reasoning**: Lock-free algorithms (Vyukov for Zig, crossbeam for Rust) should match Go's optimized runtime

**Possible outcomes**:
- **Zig/Rust win**: Proves userspace lock-free can beat Go's runtime
- **Go wins**: Go's runtime optimizations are significant (still impressive if within 10-20%)
- **Roughly equal**: All approaches are viable, choice depends on other factors

### Hypothesis 2: Rust and Zig perform similarly
**Reasoning**: Both use lock-free bounded queues without runtime overhead

**Expected**: Within 5% of each other (measurement noise)

### Hypothesis 3: Koru matches Zig/Rust
**Reasoning**: Koru events compile to direct calls, rings are the same underneath

**If true**: Zero-cost abstraction proven
**If false**: Compiler needs optimization

---

## Running The Benchmark

### Automatic (via regression suite)
```bash
./run_regression.sh 2004
```

### Manual
```bash
cd tests/regression/2000_PERFORMANCE/2004_rings_vs_channels
bash benchmark.sh
```

### View Results
```bash
cat results.json | jq
```

---

## Interpreting Results

### Sample Output
```
Performance Results:
  Go (channels):        0.128s
  Zig (MPMC ring):      0.121s
  Rust (crossbeam):     0.119s
  Koru (events):        0.123s

  Ratios:
    Zig/Go:       0.9453x
    Rust/Go:      0.9297x
    Rust/Zig:     0.9835x
    Koru/Zig:     1.0165x
    Koru/Rust:    1.0336x

✅ Rust is FASTEST (7% faster than Go!)
✅ Zig matches Rust (within 2%)
✅ Koru matches baseline (1.7% overhead - zero-cost!)
```

**Interpretation**: Lock-free approaches compete with (and beat!) Go's runtime, and Koru's abstractions are truly zero-cost!

### Real-World Implications

**If Zig/Rust beat Go**:
- Lock-free atomics can beat Go's channel runtime
- Zero-runtime concurrency is viable
- Proves systems languages can compete with Go's concurrency story

**If all roughly equal**:
- Multiple approaches are competitive
- Choice comes down to language features and ecosystem
- Koru gets best of all worlds (high-level + zero runtime)

**If Go wins**:
- Go's runtime optimizations are significant
- Still impressive if Zig/Rust within 10-20%
- Proves decades of Go runtime engineering

**If Koru matches Zig/Rust**:
- Zero-cost abstractions proven
- Events compile to same code as hand-written concurrency
- High-level Koru can compete with low-level Zig/Rust

---

## Future Work

### Phase 1: Multi-Language Baseline ✅
- [x] Go channels implementation
- [x] Zig MPMC implementation
- [x] Rust crossbeam implementation
- [x] Benchmark harness with hyperfine
- [x] Validation script

### Phase 2: Koru Integration (Current)
- [x] Implement `$std/rings` with MPMC
- [x] Implement optional branches (`?|`)
- [x] Write Koru version using events
- [x] Add to benchmark
- [ ] Validate < 10% overhead vs Zig/Rust

### Phase 3: Optimize
- [ ] PGO profile of Koru version
- [ ] Compiler optimizations based on profile
- [ ] Prove PGO makes Koru even faster
- [ ] Document optimization techniques

---

## The Bigger Picture

This test is part of Koru's **"Performance as a Feature"** story:

1. **Zero-cost events** (test 2002)
2. **Zero-cost flows** (test 2001)
3. **Zero-cost taps** (test 2003)
4. **Competitive concurrency** (this test)
5. **Profile-guided optimization** (future)

Together, these prove Koru can be **the fastest event-driven language in the world**.

Not through compiler magic, but through:
- Smart abstractions that compile away
- Lock-free algorithms from first principles
- Profile-guided optimization
- Zero-runtime overhead

---

## Credits

- **MPMC Ring**: Dmitry Vyukov's bounded MPMC queue algorithm
- **Zig Implementation**: Vendored from beist-rings
- **Rust Crossbeam**: Aaron Turon & contributors
- **Go Baseline**: Idiomatic Go concurrent patterns
- **Benchmark Tool**: hyperfine by @sharkdp

---

**Let's prove that high-level abstractions can be as fast as low-level code!** 🚀
