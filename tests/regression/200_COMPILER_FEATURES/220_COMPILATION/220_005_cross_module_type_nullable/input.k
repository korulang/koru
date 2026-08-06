// Test: Cross-module type with nullable
// PRIORITY: Nullable prefix ?* should be separate from module path
//
// The subject is the DECLARATION parsing: `?*std/interpreter:HandlePool` must
// read as nullable-pointer-to-a-cross-module-type, not as a mangled module path.
// There is no flow here, so the program prints nothing — and the expectation is
// empty on purpose. It used to claim `done`, a line this test could never have
// produced, sitting in an `expected_output.txt` the harness never opened.
import std/interpreter
import std/io

pub tor test-nullable {
    pool: ?*std/interpreter:HandlePool,
}
