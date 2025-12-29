# TCP Echo Server - Compiler Testing Findings

## What We Tested
Single-file TCP echo server with:
- 5 events (tcp.listen, tcp.accept, tcp.read, tcp.write, tcp.close)
- Nested label loops (#accept_loop, #read_loop)
- Pointer types in event shapes (*std.net.Server)
- Real Zig std.net integration

## Results

### ✅ Pass 1 (Frontend) - WORKS
- Parser handles all syntax correctly
- Shape checker validates all event flows
- Labels and nested continuations pass validation
- AST serialization successful
- **Output**: backend.zig generated (compiles with `zig build-exe`)

### ❌ Pass 2 (Backend/Codegen) - MULTIPLE BUGS FOUND

#### BUG #1: Zig keyword escaping in union branches (WORKED AROUND)

The metacircular compiler doesn't escape Zig reserved keywords when generating union branch names.

**Workaround**: Renamed `| error` branches to `| failed` in user code.

**Real fix needed**: Compiler should auto-escape keywords with `@"..."` syntax.

#### BUG #2: Inconsistent namespace prefixing in nested flows (BLOCKING)

When generating nested event calls in flows, the compiler sometimes includes the namespace prefix and sometimes doesn't.

**Example from output_emitted.zig lines 241-248**:
```zig
const nested_result_0 = .handler(.{ });           // ❌ Missing namespace!
// ...
const nested_result_1 = .handler(.{ });           // ❌ Missing namespace!
// ...
const nested_result_2 = tcp.write.handler(...);   // ✅ Has namespace
```

**Error**:
```
output_emitted.zig:248:57: error: use of undeclared identifier 'tcp'
    const nested_result_2 = tcp.write.handler(...);
                            ^~~
```

**The problem**: Earlier calls have `.handler` (no namespace), but later calls try to use `tcp.write.handler` when `tcp` isn't in scope inside the flow function.

**What's happening**: The code generator is inconsistent about whether event invocations need their full namespace path or not. Looking at line 239, the first call is `listen.handler(...)` which works because it's at the top level. But nested calls seem confused about their context.

**Workaround**: Removed namespaces (renamed `tcp.listen` → `listen`, etc). This revealed BUG #3.

#### BUG #3: Label loops not generating helper functions (BLOCKING)

When using labels for loops (`#label` and `@label`), the compiler generates tail calls to label functions but doesn't actually generate those functions.

**Example from output_emitted.zig line 252**:
```zig
return @call(.always_tail, flow0_read_loop, .{ s.conn });
//                         ^~~~~~~~~~~~~~~ Function never defined!
```

**Error**:
```
output_emitted.zig:252:68: error: use of undeclared identifier 'flow0_read_loop'
    return @call(.always_tail, flow0_read_loop, .{ s.conn });
                               ^~~~~~~~~~~~~~~
```

**The problem**: The codegen emits tail calls to `flow0_accept_loop` and `flow0_read_loop` but never generates these functions. STATUS.md line 63 confirms: "Runtime Generation: ❌ Currently crashes - needs debugging"

**This is a known issue** - labels pass validation but codegen is broken.

## What Actually Works
1. ✅ Event declarations with Zig types
2. ✅ Pointer types in shapes (*std.net.Server, std.net.Server.Connection)
3. ✅ Nested label loops (#label, @label)
4. ✅ Multiple branch continuations
5. ✅ Proc implementations with arbitrary Zig code
6. ✅ Pass 1 frontend compilation
7. ✅ AST serialization

## What Breaks
1. ❌ Using Zig keywords as branch names (BUG #1 - can work around)
2. ❌ Event namespaces in flows (BUG #2 - can work around)
3. ❌ Label loops (BUG #3 - BLOCKING, no workaround)
4. ⚠️ Pass 2 backend execution (blocked by #3)

## Conclusion

**Pass 1 (Frontend) is solid** - parser, shape checker, AST serialization all work correctly.

**Pass 2 (Backend) has critical bugs** in the metacircular compiler:
- Keyword escaping (minor)
- Namespace handling in nested flows (moderate)
- **Label code generation (BLOCKING)** - this is the showstopper

The TCP echo server successfully stress-tested the compiler and found real bugs. Without label support, we can't implement the server loop. This confirms STATUS.md's note that label runtime generation "currently crashes".
