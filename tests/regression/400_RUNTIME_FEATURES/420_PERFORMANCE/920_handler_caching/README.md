# Test 920: Handler Caching and Specialization

## Feature Summary

When multiple flows use the same subset of optional branches, generate ONE specialized handler and reuse it to avoid code duplication.

**Current behavior (Phase 3/4):**
```zig
// Each flow gets its own handler, even if they use the same branches
pub fn handler_for_flow_A(e: Input) Output { ... }  // Handles: sum, product
pub fn handler_for_flow_B(e: Input) Output { ... }  // Handles: sum, product (DUPLICATE!)
pub fn handler_for_flow_C(e: Input) Output { ... }  // Handles: all branches
pub fn handler_for_flow_D(e: Input) Output { ... }  // Handles: sum, product (DUPLICATE!)
```

**Desired behavior (Phase 5):**
```zig
// Flows A, B, D share one handler; C gets its own
pub fn handler_sum_product(e: Input) Output { ... }  // Used by A, B, D
pub fn handler_all_branches(e: Input) Output { ... } // Used by C only

// Flows just call the appropriate cached handler
flow_A: result = handler_sum_product(...)
flow_B: result = handler_sum_product(...)  // Reuses!
flow_C: result = handler_all_branches(...)
flow_D: result = handler_sum_product(...)  // Reuses!
```

## Benefits

1. **Smaller binaries**: No duplicate handler code
2. **Better optimization**: Zig can inline/optimize shared handlers
3. **Compile time**: Less code to generate and compile
4. **Maintainability**: Clearer generated code structure

## Implementation Strategy

### 1. Branch Set Tracking

```zig
// For each flow, compute which branches it uses
const BranchSet = std.StringHashMap(void);

var flow_branch_sets = std.ArrayList(BranchSet).init(allocator);
for (flows) |flow| {
    var branch_set = BranchSet.init(allocator);
    for (flow.continuations) |cont| {
        try branch_set.put(cont.branch, {});
    }
    try flow_branch_sets.append(branch_set);
}
```

### 2. Handler Cache

```zig
// Cache: BranchSet hash → Handler name
const HandlerCache = std.AutoHashMap(u64, []const u8);

fn getOrCreateHandler(
    event: *EventDecl,
    branch_set: BranchSet,
    cache: *HandlerCache
) []const u8 {
    const hash = hashBranchSet(branch_set);

    if (cache.get(hash)) |handler_name| {
        return handler_name;  // Reuse cached handler!
    }

    // Generate new specialized handler
    const handler_name = try generateHandlerName(event, hash);
    try cache.put(hash, handler_name);

    // Emit handler code (with dead branch elimination)
    try emitSpecializedHandler(event, branch_set, handler_name);

    return handler_name;
}
```

### 3. Flow Generation

```zig
// When generating a flow:
for (flows) |flow| {
    const handler_name = getOrCreateHandler(
        event,
        flow_branch_sets[i],
        &handler_cache
    );

    // Call the cached handler
    pos = writeStr(&buffer, pos, "const result = ");
    pos = writeStr(&buffer, pos, handler_name);
    pos = writeStr(&buffer, pos, "(input);\n");
}
```

## Verification

When this test passes, verify handler reuse:

```bash
# Count how many handlers were generated
grep -c "pub fn handler" tests/regression/920_handler_caching/output_emitted.zig

# Should be 2 handlers (not 4!):
# - handler_sum_product (used by flows A, B, D)
# - handler_all_branches (used by flow C)
```

Also check that flows call the right handlers:

```bash
# Flow A, B, D should call handler_sum_product
# Flow C should call handler_all_branches
grep "handler" tests/regression/920_handler_caching/output_emitted.zig
```

## Edge Cases

1. **Empty handler cache** - First flow creates handler
2. **All flows use different subsets** - No caching benefit (but no harm)
3. **All flows use same subset** - Maximum benefit (1 handler for all)
4. **Hash collisions** - Use proper hashing with collision resolution

## Test Status

⏭️ **SKIPPED** - Phase 5 not yet implemented

Depends on Phase 4 (dead code elimination) being implemented first.

## Performance Impact

With 100 flows using the same branch subset:
- **Without caching**: 100 identical handlers (~10KB each = 1MB code)
- **With caching**: 1 handler (10KB total)

**Binary size reduction**: ~99% for this pattern!
