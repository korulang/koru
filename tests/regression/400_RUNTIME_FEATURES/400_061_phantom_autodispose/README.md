# Auto-Dispose Test for Identity Branches

This test verifies auto-dispose works correctly for **identity branches** (where the return type IS the phantom-tracked value, not a struct containing it).

## Pattern

```koru
// Identity branch - the return *Resource IS the tracked value
~pub event create_resource { name: []const u8 }
| created *Resource[allocated!]

// Consumer event
~pub event destroy_resource { res: *Resource[!allocated] }
| destroyed
```

## What Gets Tested

1. Create a resource with `[allocated!]` obligation
2. Use the resource (doesn't consume the obligation)
3. DON'T manually call `destroy_resource`
4. Auto-dispose inserts the cleanup call

## Implementation Note

This test caught a bug where phantom_semantic_checker was inconsistent with auto_dispose_inserter for identity branches:

- auto_dispose tracked `r` (just the binding)
- phantom_semantic tracked `r.__type_ref` (binding.field format)

Fixed in `phantom_semantic_checker.zig` to use just the binding name for identity branches (`__type_ref`).
