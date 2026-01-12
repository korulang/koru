# Resource Lifecycle Shootout: RAII vs Koru Phantom Types

## The Thesis

**RAII (Rust/C++) couples cleanup to lexical scope. This is a fundamental limitation.**

When resources need to:
- Be created in one scope
- Used across multiple scopes
- Cleaned up in a different scope

...RAII forces ugly workarounds:
- **Flatten to primitives** (lose type safety)
- **Arc/shared_ptr** (runtime overhead)
- **Callback hell** (ergonomic nightmare)
- **Memory leaks** (Box::leak)

**Koru's phantom types decouple obligations from scope.** Resources can escape naturally, and cleanup is explicit.

## What We're Comparing

| Aspect | Rust/C++ RAII | Koru Phantom Types |
|--------|---------------|-------------------|
| Cleanup timing | At scope `}` | Explicit event |
| Cross-scope | Arc/shared_ptr | Natural escape |
| Compile-time safety | Drop runs... somewhere | Proven on ALL paths |
| Runtime cost | Atomic refcount | Zero |
| Ergonomics | Callback hell / flatten | Clean flow syntax |

## Scenarios

### 01_cross_scope_factory
Create resources in factory, use across workers, cleanup elsewhere.

**The RAII problem:**
```rust
// Can't return owned resources without Arc
fn create_files() -> Vec<Arc<Mutex<File>>> { ... }  // Overhead!

// Or flatten to primitives (dangerous!)
fn create_files() -> Vec<RawFd> { ... }  // UB if files drop!
```

**The Koru solution:**
```koru
// Obligations escape naturally via branch constructors
~create_resource = file:open(path: path)
| opened f |> created { resource: f.file }  // Obligation escapes to caller!
```

## Metrics

### Safety (Compile-time)
- What bugs does each approach catch?
- What bugs slip through?

### Performance (Runtime)
- CPU overhead (hyperfine)
- Memory overhead (heap allocations, refcount atomics)

### Ergonomics (Developer Experience)
- Lines of code
- Cognitive complexity
- Debuggability

## Running the Benchmarks

```bash
cd scenarios/01_cross_scope_factory
./benchmark.sh
```

## Status

- [x] Rust examples showing RAII pain
- [x] C++ examples showing RAII pain
- [x] Koru solution skeleton
- [ ] Benchmark scripts
- [ ] Safety comparison (what each catches)
- [ ] Full benchmark results

## The Vision

If Koru can prove:
1. **Zero runtime overhead** vs Arc/shared_ptr
2. **Compile-time safety** (no leaks, no use-after-free)
3. **Better ergonomics** (less code, clearer intent)

...then we have a compelling case that phantom types + explicit cleanup events are a superior alternative to RAII for cross-scope resource management.
