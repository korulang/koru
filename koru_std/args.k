// $std/args — Command-line argument access
//
// Safe access to the process's command-line arguments. Works on both the Zig
// and JavaScript targets.
//
// (Pure `.k` contract facet.) The public events live here, in the
// target-agnostic facet. The Zig
// implementation is in `args.kz`; the JavaScript implementation in `args.kjs`.
// `~import "std/args"` merges all same-stem facets into one module, so these
// events are in scope (unqualified) for every implementation proc.
//
// For flag parsing and CLI frameworks, see $std/cli (future).

// Get all arguments (including the program name at index 0).
pub event all {}
| args [][:0]u8

// Get the argument count.
pub event count {}
| count usize

// Get the argument at an index.
pub event get { index: usize }
| arg [:0]u8
| out-of-bounds

// Skip the program name and get the remaining arguments.
pub event rest {}
| args [][:0]u8
