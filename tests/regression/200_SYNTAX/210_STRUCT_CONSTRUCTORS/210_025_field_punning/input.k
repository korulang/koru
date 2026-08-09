// Test 210_020: Struct Field Punning
// When field value matches field name, allow shorthand: { x, y } instead of { x: x, y: y }
//
// This is the "punning" pattern common in many languages.
// The emitter should expand { c.ast, c.code } to { ast: c.ast, code: c.code }

import std/io

tor data { x: i32, y: i32 } -> { x: i32, y: i32 }

// Explicit field names (always works)
data -> { x, y }

// Test it
data(x: 10, y: 20): _ |> std/io:print.ln("explicit works")
