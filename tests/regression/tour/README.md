# Koru Language Tour

A systematic tour through all Koru language features, organized by complexity.

## Running Tour Examples

```bash
# Compile and run any example
koruc tour/01_basic/hello.kz
zig run tour/01_basic/hello.zig

# Or use the build system
zig build tour
```

## Tour Structure

### 01_basic/ - Basic Events and Procs
- `hello.kz` - Simple event/proc/flow
- `branches.kz` - Multiple branch handling
- `nested.kz` - Nested continuations

### 02_shapes/ - Shape Checking
- `simple_shapes.kz` - Basic shape validation
- `shape_errors.kz` - Examples that fail shape checking
- `complex_shapes.kz` - Nested and complex shapes

### 03_phantoms/ - Phantom Types
- `phantom_tags.kz` - Value type tags
- `phantom_states.kz` - Pointer state tracking
- `state_forwarding.kz` - State variable forwarding

### 04_labels/ - Labels and Loops
- `simple_loop.kz` - Basic label loop
- `pre_post_labels.kz` - Pre vs post invocation labels
- `nested_loops.kz` - Complex loop patterns

### 05_flows/ - Advanced Flow Control
- `pipelines.kz` - Pipeline operators
- `implicit_forwarding.kz` - Implicit branch forwarding
- `branch_constructors.kz` - Explicit branch construction

### 06_compiler/ - Compiler Coordination
- `default_compiler.kz` - Using the default compiler
- `custom_compiler.kz` - Overriding compiler.coordinate
- `extend_compiler.kz` - Extending default behavior

### 07_subflows/ - Subflow Implementations
- `simple_subflow.kz` - Basic subflow syntax
- `immediate_return.kz` - Immediate branch returns
- `flow_delegation.kz` - Delegating to other events

### 08_imports/ - Module System
- `using_imports.kz` - Basic imports
- `namespaces.kz` - Namespace management
- `circular_imports.kz` - Circular dependency handling

### 09_ast/ - AST Manipulation
- AST transformation examples

### 09_ast_transform/ - AST Transformations
- `simple_transform.kz` - Basic AST transformation
- `transform_example.kz` - Complex transformation examples

### 10_event_taps/ - Event Taps (Observer Flows)
- `basic_taps.kz` - Introduction to output and input taps
- `wildcard_taps.kz` - Using wildcards for broad observation
- `universal_profiler.kz` - System-wide profiling with transition metadata

### 11_inline_procs/ - Inline Flows in Procs
- `basic_inline.kz` - Mixing Zig code with inline flows
- `expressions_in_branches.kz` - Branch constructors with expressions
- `union_types.kz` - Working with automatically generated union types

## Feature Status

✅ Working Today:
- Basic events, procs, flows
- Shape checking
- Simple phantom types
- Labels and loops
- Subflow implementations
- Import system
- Compiler coordination (basic)
- **Inline flows in procs** (fully implemented!)
- Branch constructor expressions in proc context
- Automatic union type generation

🚧 In Progress:
- **Event Taps** (parsed and type-checked, but code generation not implemented)
- Compile-time execution
- Branch generation
- Source type
- Full phantom state forwarding

🔮 Future:
- FlowAST transformations
- Custom analyzers
- Domain-specific compilation
- Event tap code generation and runtime support