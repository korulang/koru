# Known Issue: Tap [comptime] Annotation Fails

**Status:** Currently fails at backend compilation

**Description:**
Taps with `[comptime]` annotation fail to compile with type error:
```
expected type '[][]const u8', found '*const [1][]const u8'
```

**What Should Happen:**
The tap `~[comptime]Start.done -> End` should compile successfully and be filtered out during runtime-only emission.

**What Actually Happens:**
Backend compilation fails even though:
- ast_serializer.zig correctly uses `&.{}` syntax for all annotations
- The serializer fix was applied to all 5 annotation locations
- Other annotations (on modules, events, etc.) work fine
- Tap filtering logic works correctly

**Related Tests:**
- Test 612: Works when `[comptime]` annotation removed from tap
- Test 613: Also passes without annotation

**When Fixed:**
This test will start passing and can be moved to a regular test documenting that tap annotations work correctly.
