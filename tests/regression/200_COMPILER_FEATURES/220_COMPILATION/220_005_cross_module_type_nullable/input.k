// Test: Cross-module type with nullable
// PRIORITY: Nullable prefix ?* should be separate from module path
import std/interpreter
import std/io

pub tor test-nullable {
    pool: ?*std/interpreter:HandlePool,
}
