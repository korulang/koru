// Test: for as subflow starting point
// This must work - transforms should apply to subflow bodies

import std/io
import std/control


// Event that uses for in its implementation
tor count-to-three {} -> i32

// Subflow implementation using for as the starting construct
count-to-three = for(0..3)
! each _ |> std/io:print.ln("counting")
| done -> 3

// Main flow calls the subflow
count-to-three(): _ |> std/io:print.ln("done")
