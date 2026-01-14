# Koru Testing Framework - Architecture & Gap Analysis

## The Vision

Tests are **real Koru code** where mocks are **real implementations** injected into the program AST. The normal emitter handles everything.

```koru
~test(User lookup works) {
    // Mock: this SubflowImpl becomes the event's implementation
    ~fetch_user = found { name: "Alice" }

    // Test: normal Koru flow, emitted by normal emitter
    ~fetch_user(id: 42)
    | found u |>
        assert(u.name == "Alice")
        // if we reach here, test passed
}
```

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         ~test transform                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  1. PARSE Source block                                          │
│     └─► AST items: SubflowImpls (mocks) + Flows (test code)     │
│                                                                  │
│  2. CLONE program AST (or relevant subset)                      │
│                                                                  │
│  3. INJECT mock SubflowImpls into cloned program                │
│     └─► Mocks become real implementations                       │
│                                                                  │
│  4. WALK flows for purity (post-injection)                      │
│     └─► Events with mocks are now pure (immediate return)       │
│     └─► Events still impure = ERROR (list them)                 │
│                                                                  │
│  5. EMIT using normal emitter                                   │
│     └─► No custom emission code!                                │
│                                                                  │
│  6. WRAP in test "name" { ... }                                 │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

## What We Have (DONE)

### Infrastructure ✅
- [x] `~test` event declaration with `expr: Expression` and `source: Source`
- [x] `~test` transform that receives `program`, `item`, `invocation`, `allocator`
- [x] Source block parsing via `parser_impl.Parser`
- [x] AST cloning via `ast_functional.cloneItem`
- [x] Separation of parsed items into SubflowImpls (mocks) vs Flows (test code)
- [x] Test block wrapping (`test "name" { ... }`)
- [x] Program AST replacement via `ast_functional.replaceFlowRecursive`
- [x] Access to emitter infrastructure (`emitter_helpers`)

### Purity Checking ✅
- [x] `walkFlowForPurity` - walks flow AST checking `is_pure` flags
- [x] `findProcDeclByPath` / `findEventDeclByPath` - lookup declarations
- [x] Impure event detection and error reporting

### Assertions (Partial)
- [x] `assert.ok` event + proc (but just returns `| ok |`, doesn't check anything)
- [x] `assert.fail` event + proc (panics with message)
- [ ] `assert.eq` - stubbed, needs transform
- [ ] `~assert(expr)` - doesn't exist yet

### Test Execution ✅
- [x] Generated Zig tests actually run via `zig test`
- [x] Tests are inside `test "name" {}` blocks (dead-stripped in release)

## What Needs to Change

### 1. Mock Injection (Replace Custom Emission)

**Current (wrong):**
```zig
// In emitFlowWithMocks - we inline the value at call site
if (mocks.get(inv_path)) |bc| {
    try emitter_helpers.emitBranchConstructor(emitter, ctx, &bc, true);
}
```

**New (correct):**
```zig
// Inject SubflowImpl into program AST, let normal emitter handle it
for (parsed_mocks) |mock| {
    cloned_program = injectSubflowImpl(cloned_program, mock);
}
// Then just: emitter.emitFlow(flow)  -- no special cases!
```

**Work needed:**
- [ ] Implement `injectSubflowImpl(program, subflow_impl)` - adds/replaces implementation
- [ ] Remove `emitFlowWithMocks` custom emission
- [ ] Remove mock path lookup map

### 2. Purity Walk Timing

**Current:** Runs before emission with manual mock tracking
**New:** Runs AFTER mock injection, checks if flow is transitively pure

**Work needed:**
- [ ] Move purity walk to after mock injection
- [ ] Simplify - just check `is_transitively_pure` on the flow
- [ ] Generate failing test if impure events remain

### 3. Assertions

**Current:** `assert.ok()` returns `| ok |` which is discarded - violates Koru semantics

**New:** `~assert(expr)` as a **pass-through checkpoint** (like every other assert library)

```koru
~fetch_user(id: 42)
| found u |>
    assert(u.name == "Alice") |>   // checkpoint - barfs if false
    assert(u.age == 13)            // if we reach here, test passed
```

```koru
~[keyword|comptime|transform] pub event assert {
    expr: Expression,
    ...
}
// NO BRANCHES - void pass-through

~proc assert {
    // Transform into: if (!expr) @panic("Assertion failed: {expr}");
    // Then continues - no return value, no branches
}
```

Generated Zig:
```zig
const u = result_0.found;
if (!(u.name == "Alice")) @panic("Assertion failed: u.name == \"Alice\"");
if (!(u.age == 13)) @panic("Assertion failed: u.age == 13");
// continues...
```

**Work needed:**
- [ ] Create `~assert(expr)` event + transform (simpler than `~if` - just emits if/panic)
- [ ] Remove `assert.ok` - unnecessary (test passes if it completes)
- [ ] Keep `assert.fail(message)` for explicit failures (e.g., unexpected branch reached)

### 4. Flow Validation

**Current:** Test body is parsed but not validated (no shape/flow checking)

**New:** Run validation passes on parsed test AST

**Work needed:**
- [ ] Decide: full validation or lightweight check?
- [ ] If full: run shape_checker, flow_checker on test items
- [ ] If lightweight: at minimum verify branches are handled

## Gap Analysis

| Component | Status | Gap |
|-----------|--------|-----|
| Test declaration | ✅ Done | - |
| Source parsing | ✅ Done | - |
| AST cloning | ✅ Done | - |
| Mock detection | ✅ Done | - |
| Mock injection | ❌ Missing | Need `injectSubflowImpl` |
| Custom emission | ⚠️ Delete | Remove `emitFlowWithMocks` |
| Purity walk | ✅ Done | Move timing to post-injection |
| Normal emitter | ✅ Available | Just need to call it |
| Test wrapping | ✅ Done | - |
| `assert.ok` | ⚠️ Remove | Unnecessary - test passes if it completes |
| `assert.fail` | ✅ Works | Panics correctly (for unexpected branches) |
| `~assert(expr)` | ❌ Missing | Pass-through checkpoint (simpler than `~if`) |
| Flow validation | ❌ Missing | Decide on approach |

## Code to DELETE

From `testing.kz`:
- `emitFlowWithMocks` (~70 lines)
- Mock path building and lookup map (~40 lines)
- Manual result variable naming
- Manual binding extraction

**Estimated deletion: ~120 lines**

## Code to ADD

1. `injectSubflowImpl(program, subflow_impl)` function (~30 lines?)
2. `~assert(expr)` event + transform (~100 lines, following `~if` pattern)

**Estimated addition: ~130 lines**

Net change: roughly same LOC but MUCH cleaner architecture.

## Test Status

Current 395_* tests verify:
- Compilation succeeds
- Zig test blocks are generated
- `zig test` runs them

They do NOT verify:
- Actual value checking (no working assertions)
- Branch handling in test bodies
- Semantic correctness of mock substitution

**Recommendation:** Current 395_* tests should arguably be FAILING tests since they don't verify actual values. They currently pass because:
- Compilation succeeds ✓
- Zig test blocks are generated ✓
- `zig test` runs them ✓
- But nothing actually checks any values

Once `~assert(expr)` exists, we should add tests that verify real values. The current tests prove infrastructure works.

## Next Steps (Priority Order)

1. **Implement mock injection** - Replace custom emission with AST manipulation
2. **Implement `~assert(expr)`** - Following `~if` pattern
3. **Update purity walk timing** - Run after mock injection
4. **Add assertion tests** - Tests that actually verify values
5. **Consider flow validation** - At minimum, warn on unhandled branches

## The Payoff

Once complete:
- Tests are **real Koru code** (all transforms work: `~if`, `~for`, `~capture`)
- Same emitter for tests and production
- Mocks are **real implementations** (can test events with no impl)
- `~assert(user.name == "Alice")` actually checks values
- 100% dead-stripped in production
- Infrastructure already exists - we're mostly DELETING code
