// Test: phantom obligation on a primitive string composes with sanitization.
//
// The phantom checker treats `[]const u8<unsanitized!>` exactly as it treats
// `*File<opened!>` — a value with a tracked obligation that must be
// discharged by an event accepting `<!unsanitized>`. This is taint tracking
// on top of the same machinery that handles units of measure and resource
// lifecycle, with no checker-side additions.
//
// Positive case: produce-then-sanitize-then-use compiles + runs cleanly.
// Negative twin: 330_069 (skip the sanitize, get rejected at compile time).

import std/io

pub event get-input {} -> []const u8<unsanitized!>

get-input -> "user input data"

event sanitize { input: []const u8<!unsanitized> } -> []const u8

sanitize -> input

get-input(): s |> sanitize(input: s): c |> std/io:print.ln(c)
