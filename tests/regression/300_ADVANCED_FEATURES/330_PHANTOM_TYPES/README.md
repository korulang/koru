# 909-910: Phantom Types

Tests for the phantom type-state system - compile-time tracking of runtime states.

**Range**: 909-910

## Concepts: Phantom Contracts
Phantom states can act as compile-time contracts. Instead of accumulating types, Koru accumulates contracts through **binding scope**:
```koru
~user.add_metrics(u: my_user)
| enriched m |>                  // 'm' has [metrics] contract
  analyze(u: my_user) {
    report: { .views = m.page_views } // Same memory, different contract view
  }
```
This enables polymorphism without generics or runtime overhead.

## Related
- See [400_VALIDATION](../400_VALIDATION/) for more phantom type tests (507-509)
- See [900_EXAMPLES](../900_EXAMPLES/) for ring buffer examples using phantom types
