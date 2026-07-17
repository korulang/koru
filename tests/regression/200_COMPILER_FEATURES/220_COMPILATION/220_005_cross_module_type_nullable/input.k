// Test: Cross-module type with nullable
// PRIORITY: Nullable prefix ?* should be separate from module path
import std/interpreter
import std/io

pub event test-nullable {
    pool: ?*std/interpreter:HandlePool,
}
