// TEST: Auto-synthesized proc for passthrough events
//
// When an event has:
// - Single output branch
// - Input and output fields match exactly (name + type)
// - No proc defined
//
// The compiler should synthesize a passthrough proc.

import std/io

// Event with matching input/output - NO PROC DEFINED
pub tor passthrough { msg: string } -> d |> verify(msg: d)
