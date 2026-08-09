// Test: Unexpected branch causes test failure
//
// This test verifies that if a mock returns a DIFFERENT branch than
// what the test expects, the test FAILS (not silently passes).
//
// The test expects `ok` but the mock returns `error-result`.
// This should cause a test failure due to union field access mismatch.

~import std/testing

~tor get-data {}
| ok u32
| error-result u32

~test(Unexpected branch should fail) {
    // Mock returns error-result, but test only handles ok branch
    ~get-data => error-result 500

    ~get-data()
    | ok result |> assert(result == 42)
}
