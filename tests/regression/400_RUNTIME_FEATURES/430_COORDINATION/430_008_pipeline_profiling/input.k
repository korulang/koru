// Test 430_008: Pipeline Profiling - Time Frontend Pass
//
// Override frontend pass to add timing using std/time.

import std/compiler
import std/time
import std/io

// ============================================================================
// TIMED FRONTEND (using stdlib!)
// ============================================================================

std/compiler:frontend = std/time:now(): start |> std/compiler:frontend.default(ctx): c |> std/time:report(start, label: "frontend") -> c

// The actual program
std/io:print.ln("Compiled with timed frontend!")
