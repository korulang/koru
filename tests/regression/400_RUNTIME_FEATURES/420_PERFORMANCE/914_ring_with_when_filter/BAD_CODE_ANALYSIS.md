# Test 914: Tap Invocation Bug - Bad Code Analysis

## The Test Intent

This test demonstrates the FULL consumer pattern combining:
1. **Labels** (`#consume`) for loop control
2. **Taps** (`~tap(ring.dequeue -> *)`) for observation
3. **When clauses** (`when v.data % 2 == 0`) for filtering

**Expected behavior:**
- Produce 6 values (0-5) into ring
- Loop dequeuing values
- Tap fires on each dequeue
- When clause filters for EVEN numbers only
- Process 0, 2, 4

## What The Code SHOULD Generate

```zig
consume: while (true) {
    const consume_result = dequeue_event.handler(.{ .ring = consume_ring });

    // Invoke taps AFTER the event returns
    TapRegistry.invokeOutputTaps("dequeue", consume_result);

    switch (consume_result) {
        .value => |v| {
            // Tap would be invoked here, checking when clause
            // if (v.data % 2 == 0) { process_event.handler(...) }
            continue :consume;  // CRITICAL: Keep looping!
        },
        .empty => {
            break :consume;
        },
    }
}
```

## What Was ACTUALLY Generated

```zig
consume: while (true) {
    const consume_result = dequeue_event.handler(.{ .ring = consume_ring });
    switch (consume_result) {
        .value => {
            // TODO: Handle other step types  ← BUG!
        },
        .empty => {
            break :consume;
        },
    }
}
```

**Location:** `output_emitted.zig:288`

## The Bugs

### Bug 1: No Tap Invocation
**Missing:** `TapRegistry.invokeOutputTaps()` call after `dequeue_event.handler()`

The tap registry is a **placeholder** (lines 258-269) with TODOs. Even if implemented,
it's never CALLED in the loop!

### Bug 2: Empty Handler for .value Branch
**Line 288:** Just a TODO comment, no actual code

Should:
1. Continue the loop (`continue :consume`)
2. Or invoke tap continuation directly

### Bug 3: No When Clause Evaluation
The when clause `when v.data % 2 == 0` is completely missing from generated code.

Should generate code like:
```zig
.value => |v| {
    // Inline when clause check (optimization opportunity)
    if (v.data % 2 == 0) {
        const tap_result = process_event.handler(.{ .data = v.data });
        // Handle tap result...
    }
    continue :consume;
}
```

### Bug 4: Tap Structure Not Generated
No tap functions are generated. The tap:
```koru
~tap(ring.dequeue -> *) | value v when v.data % 2 == 0 |> process(data: v.data)
    | done |> _
```

Should create a helper function or inline code to:
1. Capture the output
2. Check the when clause
3. Invoke the continuation if match
4. Handle the process result

## UPDATED: Original Hypothesis Was Wrong!

~~The README said: "I THINK this is related to the transition being back to SELF event."~~

**THIS WAS INCORRECT!**

Test 916 has the EXACT SAME self-loop pattern (`#consume` → `@consume`) and it WORKS perfectly! Test 916 generates:

```zig
.value => |__tap_payload| {
    __tap0(__tap_payload);  // ← Tap invoked!
    if (__tap_payload.data * 2 > 2) {  // ← When clause checked!
        __tap1(__tap_payload);
    }
    // TODO: Handle other step types
},
```

So taps in loops ARE supported! ✅

## Actual Root Cause

**The tap isn't being collected/generated at all!**

Searching for tap functions in test 914's output:
```bash
grep "__tap" output_emitted.zig
# → NO RESULTS!
```

**The tap collector is failing silently!**

## Why Test 916 Works But 914 Doesn't

**Test 916 tap syntax:**
```koru
~tap(ring.dequeue -> *) | value v |> process(data: v.data)
```
- NO continuation after `process`
- Implicitly terminal
- **Works!** ✅

**Test 914 tap syntax:**
```koru
~tap(ring.dequeue -> *) | value v when v.data % 2 == 0 |> process(data: v.data)
    | done |> _
```
- HAS continuation `| done |> _` after `process`
- Explicitly handles process result
- **Fails silently!** ❌

## New Hypothesis

**The tap collector fails when the tap continuation has its own continuation!**

Location to investigate:
- `src/tap_collector.zig` - Does it handle nested continuations in taps?
- `src/tap_codegen.zig` - Does it generate code for tap continuations with results?

**The bug:** Parser probably collects the tap, but tap_collector or tap_codegen
chokes on the `| done |> _` continuation and silently drops the entire tap!

## What Needs to be Fixed

### In emitter.zig or tap_codegen.zig:

1. **Generate tap invocation in loops:**
   ```zig
   while (true) {
       const result = event.handler(...);
       TapRegistry.invokeOutputTaps("event", result);  // ← Add this!
       switch (result) { ... }
   }
   ```

2. **Generate tap functions for when clauses:**
   ```zig
   fn tap_dequeue_to_process(output: dequeue_event.Output) void {
       switch (output) {
           .value => |v| {
               if (v.data % 2 == 0) {  // When clause
                   _ = process_event.handler(.{ .data = v.data });
               }
           },
           else => {},
       }
   }
   ```

3. **Register taps in TapRegistry:**
   ```zig
   const TapRegistry = struct {
       pub fn invokeOutputTaps(event_name: []const u8, output: anytype) void {
           if (std.mem.eql(u8, event_name, "dequeue")) {
               tap_dequeue_to_process(output);
           }
       }
   };
   ```

4. **Handle label continuations in taps:**
   - Tap fires
   - When clause checked
   - Continuation invoked
   - Control returns to loop
   - Loop continues to next iteration

## Test Status

**Current:** BROKEN - Produces 6 values, processes nothing
**Expected:** Produces 6 values, processes 0, 2, 4

The test compiles but doesn't execute correctly because tap invocation is
completely unimplemented for labeled loops.

## Priority

**HIGH** - This blocks a fundamental Koru pattern:
- Observable event-driven loops
- Filtered processing (when clauses)
- Separation of concerns (tap vs main flow)

This is exactly what makes Koru special for interactive/reactive systems!
