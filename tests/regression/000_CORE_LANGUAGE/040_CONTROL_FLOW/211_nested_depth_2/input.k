// ============================================================================
// VERIFIED REGRESSION TEST - DO NOT MODIFY WITHOUT DISCUSSION
// ============================================================================
// Test: Nested Continuation Depth 2 (baseline)
// Feature: Flow with 2 levels of nested continuations
// Verifies: Basic nested continuation structure works
// Depth: start |> level1 |> level2 → result
// ============================================================================

import std/io

// Simple events that add values
tor add-one { value: i32 } -> i32

add-one -> value + 1

tor add-two { value: i32 } -> i32

add-two -> value + 2

// Chain: 10 → add-one → add-two → print result
// Depth 2: Two nested continuations
// Test: 10 + 1 + 2 = 13
add-one(value: 10): a |> add-two(value: a): b |> std/io:print.ln("{{b:d}}")
