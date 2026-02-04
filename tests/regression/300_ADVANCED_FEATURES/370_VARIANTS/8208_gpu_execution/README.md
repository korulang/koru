# Test 823: GPU Shader Execution

## What This Tests

End-to-end GPU compute shader execution from Koru source code.

## The Pipeline

1. **Event Interface** - Platform-agnostic contract
   ```koru
   ~pub event double_values { data: []f32 }
   | done { }
   ```

2. **GLSL Implementation** - Variant using `|glsl`
   ```koru
   ~proc double_values|glsl {
       #version 450
       layout(local_size_x = 256) in;
       layout(binding = 0) buffer Data { float values[]; } data;
       // ... shader code ...
   }
   ```

3. **Compiler Processing** (WORK NEEDED):
   - Detect `|glsl` variant → proc body is GLSL
   - Extract GLSL source
   - Compile GLSL → SPIR-V using glslangValidator
   - Parse GLSL bindings: `layout(binding = 0) buffer Data { ... } data`
   - Match GLSL name "data" to event field "data: []f32"
   - Generate Vulkan wrapper code:
     - VkBuffer creation from `[]f32` slice
     - Descriptor set binding
     - Compute shader dispatch
     - Synchronization/wait

4. **Generated Zig Code** (pseudocode):
   ```zig
   pub fn double_values_glsl(e: Input) Output {
       const spv = @embedFile("double_values.spv");
       const device = getGPUDevice();  // Singleton

       // Create buffer from slice
       var buffer = createBuffer(device, e.data);
       defer buffer.destroy();

       // Bind and dispatch
       const pipeline = getPipeline(spv);
       bindBuffer(pipeline, 0, buffer);  // binding 0 matches GLSL
       dispatch(pipeline, workgroups);
       wait();

       // Data modified in place (buffer backed by e.data)
       return .{ .done = .{ } };
   }
   ```

## Name Matching

**Mechanical, type-directed binding:**

| Event Field | GLSL Declaration | Match |
|-------------|------------------|-------|
| `data: []f32` | `layout(binding = 0) buffer Data { float values[]; } data` | ✅ Name "data", Type []f32 → buffer |

The compiler:
1. Sees event field named "data" of type `[]f32`
2. Finds GLSL binding named "data"
3. Validates: buffer type compatible with `[]f32`
4. Generates: `bindBuffer(0, buffer_from_data)`

**No annotations needed** - the interface defines everything!

## Phantom Types (Future)

For more complex GPU operations, phantom tags provide hints:

```koru
~import gpu_types = "gpu/symbols"

~pub event blur {
    image: []f32[gpu_types.Texture2D],  // Hint: treat as texture
    width: u32,
    height: u32
}
```

But for MVP, untagged types work fine with sensible defaults:
- `[]T` → storage buffer
- Scalars → push constants or uniforms
- Compiler chooses based on size

## Current Status

**✅ Test 822**: GLSL → SPIR-V compilation works
**🚧 Test 823**: Need Vulkan binding generation (THIS TEST)
**📋 Future**: Phantom tags, multiple buffers, GPU-resident data

## Compiler Work Required

1. **Variant detection**: Recognize `|glsl` → GLSL body
2. **GLSL extraction**: Extract shader source from proc body
3. **Binding parsing**: Parse GLSL `layout(binding = N)` declarations
4. **Name matching**: Match GLSL names to event field names
5. **Vulkan codegen**: Generate VkBuffer/descriptor/dispatch code
6. **Integration**: Wire up generated handler to event dispatcher

## Running This Test

Currently this test will **fail to compile** because the `|glsl` variant support doesn't exist yet.

Once implemented, it should:
```
$ ./run_regression.sh 823
✅ GPU execution successful! All values doubled.
```
