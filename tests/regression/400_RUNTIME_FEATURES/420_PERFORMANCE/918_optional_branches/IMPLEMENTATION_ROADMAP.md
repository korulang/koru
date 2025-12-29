# Optional Branches - Implementation Roadmap

## Feature Overview

Optional branches allow event designers to mark certain branches as non-essential, enabling:
1. **API Evolution** - Add branches without breaking existing code
2. **Zero-Cost Abstractions** - Rich APIs where handlers only pay for what they use
3. **Dead Branch Elimination** - Compiler removes unused branch code paths

## Implementation Phases

### Phase 1: Parser & AST ✅ (Current)
**Goal**: Accept `?` syntax and mark branches as optional in AST

**Files to modify**:
- `src/parser.zig` - Parse `?` prefix in branch declarations
- `src/ast.zig` - Add `is_optional: bool` field to Branch struct

**Changes**:
```zig
// In ast.zig
pub const Branch = struct {
    name: []const u8,
    payload: Shape,
    is_deferred: bool,
    is_optional: bool,  // ← ADD THIS
};

// In parser.zig, around line ~400-500 (branch parsing)
// After '|', check for '?':
if (self.peek() == '?') {
    _ = self.advance(); // consume '?'
    is_optional = true;
}
```

### Phase 2: Shape Checker
**Goal**: Allow flows to skip optional branches

**Files to modify**:
- `src/shape_checker.zig` - Branch coverage validation

**Changes**:
```zig
// In checkSourceFile, around branch coverage checking
// When checking if all branches are handled:
for (event.branches) |branch| {
    if (!branch.is_optional && !is_handled(branch.name)) {
        // ERROR: Required branch not handled
    }
    // Optional branches: no error if not handled
}
```

### Phase 3: Code Generation (Basic)
**Goal**: Generate correct code (no optimization yet)

**Files to modify**:
- `src/ast_serializer.zig` - Serialize `is_optional` field
- `koru_std/compiler_bootstrap.kz` - Include all branches in union

**Changes**:
- Serialize `is_optional` to backend.zig AST
- Generate union with ALL branches (required + optional)
- Generate handler with ALL code paths (no elimination yet)

**Test**: Remove SKIP file from test 918, verify it compiles and runs

### Phase 4: Dead Branch Elimination (Advanced) 🚀
**Goal**: Eliminate code for unused optional branches

**Strategy**:
1. **Flow Analysis**: Track which branches each flow actually handles
2. **Specialization**: Generate specialized handler per call site
3. **Caching**: Reuse handlers when multiple flows use same branch subset

**Files to modify**:
- `koru_std/compiler_bootstrap.kz` - Handler generation logic

**High-Level Algorithm**:
```
for each flow F:
    branches_used = F.continuations.map(c => c.branch)

    if handler_exists_for(event, branches_used):
        emit: call existing specialized handler
    else:
        emit: new specialized handler
        only include code paths that lead to branches_used
```

**Implementation Details**:

1. **Before generating handler**:
```zig
// Collect which branches this specific flow uses
var used_branches = std.ArrayList([]const u8).init(allocator);
for (flow.continuations) |cont| {
    try used_branches.append(cont.branch);
}
```

2. **When processing proc return statements**:
```zig
// If returning optional branch not in used_branches, SKIP this code path
if (branch.is_optional and !used_branches.contains(branch.name)) {
    // Don't emit this return path
    continue;
}
```

3. **Challenges**:
- Control flow analysis (when does code lead to which branch?)
- Zig `if`/`while` statements with early returns
- Need to parse Zig code in proc body (complex!)

**Simplified Approach** (for MVP):
- Only eliminate straight-line returns: `return .{ .optional_branch = ... };`
- Don't try to analyze complex control flow
- Still provides value for common patterns

### Phase 5: Optimization & Caching
**Goal**: Avoid code duplication when multiple flows use same branches

**Implementation**:
```zig
// Cache: EventName -> BranchSet -> HandlerName
var handler_cache = std.StringHashMap(HandlerInfo).init(allocator);

fn getOrCreateHandler(event: []const u8, branches: [][]const u8) []const u8 {
    const cache_key = hash(event, branches);
    if (handler_cache.get(cache_key)) |handler| {
        return handler.name;
    }

    const new_handler = generateSpecializedHandler(event, branches);
    handler_cache.put(cache_key, new_handler);
    return new_handler.name;
}
```

## Testing Strategy

### Test 918: Basic Optional Branches
- Event with required + optional branches
- Flow handles only required
- Verifies compilation succeeds

### Test 919: Dead Code Elimination (Phase 4)
- Manually inspect generated code
- Verify optional branch code is NOT present
- Compare binary size

### Test 920: Multiple Specializations (Phase 5)
- Multiple flows using different branch subsets
- Verify each gets correct specialized handler
- Verify handlers are reused when possible

## Migration Path

**Backward Compatible**: All existing code continues to work
- No `?` means required (current behavior)
- Can add `?` to existing events without breaking handlers that already use those branches

**Forward Compatible**: Can make branches required later
- Change `?branch` to `branch`
- Compiler will error on flows that don't handle it
- Clear migration path

## Notes

- Dead branch elimination (Phase 4) is the HARD part
- Phases 1-3 are straightforward and provide immediate value
- Phase 4 can be done incrementally (start simple, improve over time)
- The feature is useful even without Phase 4 (API evolution still works!)
