// Test: Constant events auto-inline without explicit mock
//
// Events defined with immediate branch constructors (SubflowImpl.body.immediate)
// are automatically inlined in tests - no mock needed!
// This is the TOTAL FLEX - compile-time flow pruning for free.

import std/testing

// Event with constant implementation (immediate branch constructor)
event get-config {} -> { timeout: u32, retries: u32 }

// Constant implementation - always returns the same value
get-config -> { timeout: 30, retries: 3 }

// Test: NO MOCK NEEDED - constant is auto-detected and inlined!
// Verify the constant values are correct
test(Constant event auto-inlined) {
    get-config(): c |> assert(c.timeout == 30)
}

