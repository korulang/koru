// Test 210_041: Expression Backslash Escape
// Tests that strings with escaped backslashes parse correctly.
// "path\\to\\file" should NOT be flagged as Zig code (\\t ≠ \t).


event process-path { path: []const u8 }
