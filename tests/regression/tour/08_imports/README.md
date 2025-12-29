# Tour 08: Imports and Module System

This section demonstrates Koru's module and import system, showing how to organize code across multiple files and share functionality between modules.

## Files in this tour

### Core Examples
1. **basic_imports.kz** - Introduction to importing events from other modules
   - Default namespace imports
   - Custom namespace aliases
   - Using imported events with namespace prefixes
   - What can and cannot be imported

2. **namespaces.kz** - Advanced namespace management
   - Avoiding naming conflicts
   - Semantic namespace aliases
   - Best practices for namespace organization
   - Common namespace patterns

3. **circular_demo.kz** - Circular dependency handling
   - How Koru resolves circular imports
   - When circular dependencies are appropriate
   - Best practices for managing dependencies

### Supporting Modules
These modules provide events that are imported by the examples above:

- **math_utils.kz** - Mathematical operations (add, multiply, divide)
- **logger.kz** - Logging functionality (info, error, debug, configure)
- **file_ops.kz** - File operations (read, write, exists)
- **circular_a.kz** - First module in circular dependency example
- **circular_b.kz** - Second module in circular dependency example

## Key Concepts

### What Can Be Imported
- ✅ Public events (marked with `~pub event`)
- ✅ Event shapes (the structure of events and their branches)

### What Cannot Be Imported
- ❌ Private events (without `pub` keyword)
- ❌ Procs (implementations are always private)
- ❌ Local variables or constants
- ❌ Type definitions (unless part of event shapes)

### Import Syntax
```koru
// Default import - namespace is filename without extension
~import "math_utils.kz"        // Available as math_utils:

// Custom namespace
~import "math_utils.kz" => math  // Available as math:
```

### Using Imported Events
```koru
// Must use namespace prefix with : (colon)
~math:add(a: 1, b: 2)
| sum s |> // Handle result

// Cannot use without prefix
~add(a: 1, b: 2)  // ERROR: No event 'add'
```

## Testing Import Features

These examples are designed to test that the Koru compiler correctly implements the module system as specified in SPEC.md. Key areas tested:

1. **Namespace resolution** - Events must be called with correct namespace
2. **Public/private visibility** - Only public events are accessible  
3. **Circular dependencies** - Properly resolved at compile time
4. **Import errors** - Duplicate imports, missing files, private access
5. **Namespace conflicts** - Multiple modules with same event names

## Running the Examples

Each example can be compiled and run independently:

```bash
koruc tour/08_imports/basic_imports.kz
koruc tour/08_imports/namespaces.kz  
koruc tour/08_imports/circular_demo.kz
```

The supporting modules don't have main flows and are only meant to be imported.