// Test: Basic test transform with mock substitution
//
// Tests that:
// 1. Mocks are substituted inline (flow pruning)
// 2. Bindings are extracted from mocked branch values
// 3. Assert can verify actual values

import std/testing

// Impure event - needs mock in tests (no proc = impure by default)
tor get-balance {} -> u32

// Test: Mock value is inlined, binding extracted, value verified
test(Mock value inlined with binding) {
    get-balance -> 100
    get-balance(): a |> assert(a == 100)
}

