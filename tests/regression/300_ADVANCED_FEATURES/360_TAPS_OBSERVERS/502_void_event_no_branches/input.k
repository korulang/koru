// ============================================================================
// VERIFIED REGRESSION TEST - DO NOT MODIFY WITHOUT DISCUSSION
// ============================================================================
// Test 502: Void event with no branch handlers
// Tests that shape checker allows void events without branch handlers
// Demonstrates: Events with no output branches work correctly

import std/io

// Void events have no output branches, so no branch handling required
std/io:print.ln("First line")
std/io:print.ln("Second line")
std/io:print.ln("Third line")
