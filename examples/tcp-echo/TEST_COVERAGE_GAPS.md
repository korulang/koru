# Test Coverage Gaps Revealed by TCP Echo Server

## The Alarming Reality

The TCP echo server is ~100 lines of straightforward code implementing a basic network server. It **immediately found 3 bugs**, all of which should have been caught by existing tests.

## What This Reveals About Test Coverage

### Existing Tests Are Too Simple

**100-series (Basics)**
- 101: Pure Zig (no Koru at all)
- 102: Event declaration (no execution)
- 103: Single event flow
- 104: Two sequential flows
- 105: Void events

**200-series (Features)**
- 201: Multiple branches
- 202: Binding scopes (shallow nesting)
- 203: Labels (SINGLE loop only)
- 205: Branch constructors

### Critical Gaps

#### 1. No Namespace Testing
**What was missing**: Events with namespaces like `net.connect`, `file.read`, `tcp.listen`

**Why it matters**: Namespaces are a CORE feature for organizing code. The tutorial shows `tcp.accept`, `file.read`, etc. as primary examples.

**What broke**: Namespace prefixing in nested flows (BUG #2)

**Should have had**:
- Test with `foo.bar` event calling `foo.baz` event
- Test with multiple namespaced events in a chain
- Test with nested continuations on namespaced events

#### 2. No Nested Label Testing
**What was missing**: Labels within labels (`#outer` containing `#inner`)

**Why it matters**: Server loops ALWAYS have this pattern:
```
#accept_loop
  | connection |> #read_loop
    | data |> @read_loop    // Inner loop
    | closed |> @accept_loop // Outer loop
```

**What broke**: Nested label function generation (BUG #3)

**Should have had**:
- Test with two labels in same flow
- Test with label inside label continuation
- Test with multiple jumps to different labels

#### 3. No Zig Keyword Testing
**What was missing**: Branch names that are Zig keywords (`error`, `return`, `async`, etc.)

**Why it matters**: `error` is THE MOST COMMON branch name for error handling! Almost every event should have an error branch.

**What broke**: Keyword escaping in codegen (BUG #1)

**Should have had**:
- Test for every Zig keyword as branch name
- Test mixing keyword and non-keyword branches
- Test keyword branches in nested flows

#### 4. No "Real Code" Stress Tests
**What was missing**: Anything resembling actual application code

**Existing tests are all toys**:
- Count to 5
- Print "hello"
- Return a number
- Check if positive/negative

**Real code does**:
- Chain multiple events together
- Nest continuations 3-4 levels deep
- Use multiple namespaces
- Handle errors at every level
- Loop with complex state

**The TCP server is the FIRST test that**:
- Uses pointer types in events
- Has nested loops
- Chains 4+ events together
- Handles errors in nested contexts
- Uses namespaces

## Impact

**Bugs that made it through**:
1. Keyword escaping - Should have been caught day 1
2. Namespace handling - Should have been caught before namespaces shipped
3. Nested labels - Should have been caught before labels shipped

**What this means**:
- Test suite validates syntax parsing
- Test suite validates trivial code generation
- Test suite does NOT validate real-world code

## Recommendations

### Immediate
1. Add namespace tests for all existing features
2. Add nested label tests
3. Add keyword escaping tests for ALL Zig keywords
4. Add at least 3 "realistic" examples:
   - HTTP server (like our TCP server)
   - File processor (read → parse → transform → write)
   - State machine (multiple nested states with transitions)

### Medium-term
1. Every feature PR must include:
   - Simple test (what works in isolation)
   - Composition test (what works when combined)
   - Stress test (what works at scale/depth)
2. Test coverage metric: % of feature combinations tested, not % of features
3. "Real code" test suite with actual applications

### Long-term
1. Generative testing: randomly compose features and verify compilation
2. Fuzzing: random valid Koru programs to find edge cases
3. Benchmark suite: real applications at scale

## The Bottom Line

The test suite is **syntactically correct** but **semantically shallow**.

It tests that each feature works in isolation. It does NOT test that features work together, which is what actual programs do.

The TCP echo server is ~100 lines and found 3 bugs. That's a **3% bug density against existing tests**.

If we had 10 more realistic examples, we'd likely find 30 more bugs.
