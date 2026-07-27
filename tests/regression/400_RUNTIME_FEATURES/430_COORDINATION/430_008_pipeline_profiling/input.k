// Test 430_008: Pipeline Profiling - Time Frontend Pass
//
// Override the elaborate pass to add timing using std/time.

import std/compiler
import std/time
import std/io

// ============================================================================
// TIMED FRONTEND (using stdlib!)
// ============================================================================

std/compiler:elaborate = std/time:now(): start |> std/compiler:elaborate.default(ctx): c |> std/time:report(start, label: "elaborate") -> c

// The actual program
std/io:print.ln("Compiled with timed elaborate!")
