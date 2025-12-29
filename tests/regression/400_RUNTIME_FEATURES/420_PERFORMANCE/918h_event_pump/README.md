# Test 918h: Optional Branches - Event Pump Loop Pattern (THE USE CASE)

## What This Test Verifies

This test demonstrates **THE motivating use case** for optional branches: wrapping event-based APIs like WIN32, SDL, or other event systems.

**The problem optional branches solve:**
- Event systems have dozens or hundreds of event types
- You only care about a subset (e.g., keyboard and mouse, not timer/window/system events)
- You need a loop that continuously pumps events
- Without optional branches: exhaustive handling would be unbearable

## The Pattern

```koru
~pub event pump {}
| ?mouse_event { x: i32, y: i32, button: i32 }
| ?keyboard_event { code: i32 }
| ?window_event { type: i32 }
| ?timer_event { id: i32 }
| ?quit {}
// ... imagine 50+ more event types

// Loop using label/jump pattern
~#pump_loop pump()
| mouse_event m |> handle_mouse(m.x, m.y, m.button) |> @pump_loop
| keyboard_event k |> handle_keyboard(k.code) |> @pump_loop
| quit |> _  // Exit loop
|? |> @pump_loop  // Ignore all other events, continue loop

// Loop continues even when unhandled events fire
// Without |?, loop would stop on first window_event
```

**Why this works:**
- `|?` satisfies the branch interface for all unhandled optional branches
- When `timer_event` fires → caught by `|?` → execution continues → loop continues
- Without `|?` → `timer_event` fires → no handler → execution stops → loop dies

## The Alternative (Without Optional Branches)

**Option 1**: Exhaustive handling (unbearable)
```koru
~#pump_loop pump()
| mouse_event m |> handle_mouse(...) |> @pump_loop
| keyboard_event k |> handle_keyboard(...) |> @pump_loop
| window_event w |> @pump_loop  // Explicit no-op
| timer_event t |> @pump_loop    // Explicit no-op
| system_event s |> @pump_loop   // Explicit no-op
// ... 50+ more branches all need explicit handling
```

**Option 2**: Hide loop in Zig (bad for visibility)
```zig
// Zig code
while (true) {
    const event = pollEvent();
    switch (event) {
        .mouse => call_koru_mouse_handler(...),
        .keyboard => call_koru_keyboard_handler(...),
        else => continue,
    }
}
```
Problem: Loop is hidden in foreign code, intent is obscured.

**Option 3**: Optional branches + `|?` (elegant)
```koru
~#pump_loop pump()
| mouse_event m |> handle_mouse(...) |> @pump_loop
| keyboard_event k |> handle_keyboard(...) |> @pump_loop
|? |> @pump_loop  // Catches all other optional events
```
Loop visible in Koru, selective handling, execution continues.

## Test Structure

This test uses a simulated event pump that returns different event types:

```koru
~event pump { iteration: u32 }
| ?mouse_event { code: i32 }
| ?keyboard_event { code: i32 }
| ?window_event { code: i32 }
| ?timer_event { code: i32 }
| ?quit {}

~proc pump {
    // Deterministically return different events based on iteration
    // Simulates real event pump behavior
    // After 8 iterations, returns quit to exit loop
}

// Loop using label/jump pattern
~#pump_loop pump(iteration: 0)
| keyboard_event k |> handle(k.code) |> @pump_loop(iteration: iteration + 1)
| mouse_event m |> handle(m.code) |> @pump_loop(iteration: iteration + 1)
| quit |> _  // Exit the loop
|? |> @pump_loop(iteration: iteration + 1)  // Catch other events, continue loop
```

## Critical Behavior

**Without `|?`:**
- Loop iteration 3 returns `window_event`
- Handler has no `window_event` continuation
- Branch interface not satisfied
- **Execution stops, loop dies**

**With `|?`:**
- Loop iteration 3 returns `window_event`
- No explicit handler, but `|?` catches it
- Branch interface satisfied
- **Execution continues, loop continues**

This is why `|?` is essential for event pumps.

## Test Behavior

The test runs a loop that:
1. Calls `~pump()` with iteration counter
2. Handles `keyboard_event` and `mouse_event` explicitly
3. Uses `|?` to catch `window_event` and `timer_event`
4. Continues looping for 10 iterations

Expected output shows:
- Explicit handling for keyboard/mouse events
- Generic handling for window/timer events
- Loop completes all 10 iterations successfully

## Test Coverage

Part of comprehensive optional branches test suite:
- **Test 918**: Basic `|?` catch-all pattern
- **Test 918b**: Mix explicit handling + `|?` catch-all
- **Test 918d**: Shape validation (negative test)
- **Test 918e**: All optional + only `|?` (edge case)
- **Test 918f**: API evolution (anti-F# discard)
- **Test 918g**: `when` guards + `|?` interaction
- **Test 918h** (this): Event pump loop pattern ← **THE USE CASE!**
- **Test 918i**: Error case without `|?` (runtime behavior)

## Files

- `input.kz` - Event pump loop with selective handling
- `expected.txt` - All 10 iterations complete successfully
- `MUST_RUN` - Requires execution
- `README.md` - This file
