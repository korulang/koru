# GPU Shader Compiler Integration Design

## Status

✅ **GLSL → SPIR-V compilation works** (test 822)
✅ **Mock GPU runtime demonstrates the API** (this test)
✅ **Generated code example proves the concept** (demo_generated_code.zig)
🚧 **Compiler integration needed** - make koruc actually generate this!

## What We Have

### Working Components

1. **GLSL → SPIR-V Compilation** (`test 822`)
   - `glslangValidator` successfully compiles GLSL to SPIR-V
   - SPIR-V binaries are 800-900 bytes for simple shaders
   - Compiler can shell out to glslangValidator at comptime

2. **Mock GPU Runtime** (`mock_gpu_runtime.zig`)
   - Simulates the full GPU API without requiring Vulkan drivers
   - Provides same interface as real `gpu_runtime.zig`
   - Perfect for testing compiler integration

3. **Real Vulkan Runtime** (`gpu_runtime.zig`)
   - Complete implementation ready to use
   - Supports buffer creation, pipeline setup, and dispatch
   - Currently blocked by missing Vulkan drivers on this machine

4. **Generated Code Demo** (`demo_generated_code.zig`)
   - Shows EXACTLY what compiler should generate
   - Proves the design works end-to-end
   - Uses @embedFile() for SPIR-V

## Koru Source → Generated Zig Mapping

### Input: Koru Source (`input.kz`)

```koru
~pub event double_values { data: []f32 }
| done { }

~proc double_values|glsl {
    #version 450
    layout(local_size_x = 256) in;
    layout(binding = 0) buffer Data { float values[]; } data;

    void main() {
        uint idx = gl_GlobalInvocationID.x;
        if (idx < data.values.length()) {
            data.values[idx] *= 2.0;
        }
    }
}
```

### Output: Generated Zig

```zig
pub const double_values = struct {
    pub const Input = struct {
        data: []f32,
    };

    pub const Output = union(enum) {
        done: struct {},
    };

    // GLSL variant handler
    pub fn handler_glsl(e: Input) Output {
        // Embedded SPIR-V (compiled at comptime)
        const spv_code = @embedFile("double_values.spv");

        var buffer = gpu.createBuffer(f32, e.data) catch unreachable;
        defer buffer.destroy();

        var pipeline = gpu.createComputePipeline(spv_code, 1) catch unreachable;
        defer pipeline.destroy();

        gpu.bindBuffer(&pipeline, 0, &buffer) catch unreachable;

        const local_size_x = 256;
        const workgroups = (e.data.len + local_size_x - 1) / local_size_x;
        gpu.dispatch(&pipeline, @intCast(workgroups), 1, 1) catch unreachable;

        gpu.readBuffer(f32, &buffer, e.data) catch unreachable;

        return .{ .done = .{} };
    }

    pub fn handler(e: Input) Output {
        return handler_glsl(e);
    }
};
```

## Compiler Work Required

### 1. Variant Detection in Parser
- Recognize `~proc event_name|variant { }` syntax
- Store variant name in AST (`proc.variant = "glsl"`)
- Already supported! Just need to use it in emitter

### 2. GLSL Body Extraction
When emitter sees `proc.variant == "glsl"`:
- Don't parse body as Zig code
- Extract raw string from proc body
- Write to temp file: `<event_name>.comp`

### 3. Compile GLSL → SPIR-V (Comptime!)
```zig
// In emitter, at comptime:
const glsl_path = "/tmp/<event_name>.comp";
const spv_path = "/tmp/<event_name>.spv";

// Shell out to glslangValidator
const result = try std.process.Child.run(.{
    .allocator = allocator,
    .argv = &[_][]const u8{
        "glslangValidator", "-V", glsl_path, "-o", spv_path
    },
});

if (result.term.Exited != 0) {
    @compileError("GLSL compilation failed: " ++ result.stderr);
}
```

### 4. Parse GLSL Bindings
Parse the GLSL source to extract:
- `layout(binding = N)` → binding index
- `buffer Name { ... } name` → buffer name and binding

Example:
```glsl
layout(binding = 0) buffer Data { float values[]; } data;
```
Extracts:
- Binding 0
- Name: "data"
- Type: storage buffer

### 5. Match to Event Fields
- Event field: `data: []f32`
- GLSL buffer: `buffer Data { ... } data`
- Match by name: "data" == "data" ✅
- Validate type: `[]f32` → storage buffer ✅

### 6. Generate Handler Code
Template:
```zig
pub fn handler_<variant>(e: Input) Output {
    const spv_code = @embedFile("<event_name>.spv");

    // For each matched field/binding:
    var buffer_<field> = gpu.createBuffer(<T>, e.<field>) catch unreachable;
    defer buffer_<field>.destroy();

    var pipeline = gpu.createComputePipeline(spv_code, <binding_count>) catch unreachable;
    defer pipeline.destroy();

    // For each binding:
    gpu.bindBuffer(&pipeline, <binding_index>, &buffer_<field>) catch unreachable;

    // Parse local_size_x from GLSL or default to 256
    const local_size_x = <parsed_or_default>;
    const workgroups = (e.<first_buffer_field>.len + local_size_x - 1) / local_size_x;

    gpu.dispatch(&pipeline, @intCast(workgroups), 1, 1) catch unreachable;

    // Read back modified buffers
    gpu.readBuffer(<T>, &buffer_<field>, e.<field>) catch unreachable;

    return .{ .done = .{} };  // Or parse from branches
}
```

### 7. Copy SPIR-V to Output
- Copy generated `<event_name>.spv` next to `output_emitted.zig`
- Make sure `@embedFile()` can find it

## Name Matching Algorithm

**Core principle: Event interface defines the contract, GLSL follows it**

```
For each event input field:
    1. Find GLSL binding with matching name
    2. Validate type compatibility:
       - []T → storage buffer ✅
       - T (scalar) → push constant or uniform ✅
    3. Generate binding code

If GLSL binding has no matching field → compile error
If field has no matching binding → compile error (or warning?)
```

## Type Mapping

| Koru Type | GLSL Type | Vulkan Binding |
|-----------|-----------|----------------|
| `[]f32` | `buffer { float values[]; }` | Storage buffer |
| `[]u32` | `buffer { uint values[]; }` | Storage buffer |
| `[]i32` | `buffer { int values[]; }` | Storage buffer |
| `u32` | `uniform uint` or push constant | Uniform/Push |
| `f32` | `uniform float` or push constant | Uniform/Push |

## Phantom Types (Future)

```koru
~import gpu = "gpu/symbols"

~pub event blur {
    image: []f32[gpu.Texture2D],  // Hint: treat as 2D texture
    width: u32,
    height: u32,
}
```

For MVP: Ignore phantom types, use sensible defaults
- `[]T` → storage buffer (simplest)
- Scalars → push constants (if <128 bytes) or uniform buffer

## Error Handling

### Compile-Time Errors (via @compileError)
1. GLSL compilation fails
2. GLSL binding name doesn't match event field
3. Type mismatch (e.g., `[]f32` vs `int` in GLSL)
4. No bindings found in GLSL

### Runtime Errors (via error unions)
Only if using real GPU:
- Vulkan initialization fails
- Out of memory
- Device lost

Mock runtime uses `unreachable` - simulation can't fail!

## Testing Strategy

### Phase 1: Mock Runtime ✅
- Use `mock_gpu_runtime.zig`
- Test compiler codegen without GPU
- Fast iteration

### Phase 2: Real Runtime
- Switch to `gpu_runtime.zig`
- Require Vulkan drivers
- Prove it actually runs on GPU

### Phase 3: CI
- Mock runtime in CI (no GPU required)
- Real runtime only on machines with GPU
- Clear separation: compiler tests vs runtime tests

## Integration Checklist

- [ ] Parser: Store variant name in AST
- [ ] Emitter: Detect `|glsl` variant
- [ ] Emitter: Extract GLSL body to temp file
- [ ] Emitter: Shell out to `glslangValidator`
- [ ] Emitter: Parse GLSL bindings (regex or simple parser)
- [ ] Emitter: Match bindings to event fields
- [ ] Emitter: Generate handler_<variant> code
- [ ] Emitter: Copy SPIR-V to output directory
- [ ] Emitter: Generate dispatcher (handler → handler_glsl)
- [ ] Test: Verify with mock_gpu_runtime
- [ ] Test: Verify with real gpu_runtime (when available)

## Files in This Test

```
823_gpu_execution/
├── README.md                       # High-level overview
├── COMPILER_INTEGRATION.md         # This document
├── input.kz                        # Koru source (target)
├── demo_generated_code.zig         # What compiler should generate
├── mock_gpu_runtime.zig            # Mock GPU for testing
├── gpu_runtime.zig                 # Real Vulkan runtime (ready!)
├── double_values.comp              # GLSL source
├── double_values.spv               # SPIR-V binary
└── test_vulkan_runtime.zig         # Manual Vulkan test
```

## Next Steps

1. **Implement variant detection in emitter**
   - Check if `proc.variant != null`
   - Branch to GLSL codegen path

2. **Write GLSL extraction code**
   - Get proc body as string
   - Write to temp file with `.comp` extension

3. **Add glslangValidator call**
   - Shell out at comptime
   - Handle errors with @compileError

4. **Implement basic name matching**
   - Parse `layout(binding = N) buffer ... name`
   - Match `name` to event field name
   - Generate binding code

5. **Test with test 823**
   - Should compile and run successfully
   - Mock runtime executes logic on CPU
   - Proves compiler integration works

## Success Criteria

✅ `./run_regression.sh 823` compiles without errors
✅ Generated code matches `demo_generated_code.zig` structure
✅ Test executes and validates results
✅ SPIR-V file is generated and embedded
✅ Mock runtime demonstrates correct execution flow
