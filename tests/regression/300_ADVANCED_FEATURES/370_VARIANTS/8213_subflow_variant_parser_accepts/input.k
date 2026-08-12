// Test 8213: Parser accepts subflow declarations with |variant tags.
//
// Symmetry with procs: proc name|variant { ... } already works.
// This test pins event_name|variant = subflow_body for Koru-transparent
// implementations. The compiler can see both arms; dispatch uses the same
// variant registry that proc variants use.
//
// Minimal shape: one event, two subflow variants, build:variants picks one.

import std/io
import std/build


pub tor greet {}

// Two semantically-different subflows under one canonical event name.
greet|en = std/io:print("hello")

greet|no = std/io:print("hei")

// Register the |en variant program-wide.
std/build:variants {
    "input:greet": "en"
}
| configured _ |> _
| skipped _ |> _
| invalid-event _ |> _

greet()
