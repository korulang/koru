# Test 103: Invocation Parentheses Rules

## Design Decision

This test captures the grammar rules for when parentheses are required or forbidden in event invocations.

## The Rules

### Rule 1: No source block → `()` required
```koru
~voidCall()              // ✅ Correct
~voidCall                // ❌ Parser error
```

### Rule 2: Source block with zero other params → NO `()`
```koru
~renderHTML [HTML]{ }         // ✅ Correct
~renderHTML() [HTML]{ }       // ❌ Parser error
```

### Rule 3: Source block with params → `()` required for params
```koru
~render(name: "Bob") [HTML]{ }    // ✅ Correct
~render name: "Bob" [HTML]{ }     // ❌ Parser error
```

### Rule 4: Source block without `[]` → Parser error
```koru
~renderHTML [HTML]{ }        // ✅ Correct (with phantom type)
~renderHTML []{ }            // ✅ Correct (empty phantom type)
~renderHTML { }              // ❌ Parser error (missing [] leader)
```

## Why These Rules?

1. **Consistency**: One way to express each situation, no optionality
2. **Visual clarity**: `[Type]{ }` syntax is distinctive and signals "special implicit parameter"
3. **No magic**: Regular invocations always use `()`, source blocks always use `[]{ }`
4. **Unambiguous**: No confusion with branch constructors or other syntax

## Implementation Status

Currently tests VALID cases only. Invalid cases are documented in comments.

Future work: Add MUST_FAIL tests for the invalid cases to ensure parser rejects them properly.
