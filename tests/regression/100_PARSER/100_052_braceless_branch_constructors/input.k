// Test: Braceless branch constructor syntax
//
// Syntax: ok expr (branch with single value)

import std/io

// Event with value branch
pub tor value-result {} -> i32

// Subflow impl using braceless syntax with value
value-result -> 42

// Main entry point
std/io:print.ln("Testing value braceless:")
value-result(): n |> std/io:print.ln("  Got success: {{ n:d }}")
