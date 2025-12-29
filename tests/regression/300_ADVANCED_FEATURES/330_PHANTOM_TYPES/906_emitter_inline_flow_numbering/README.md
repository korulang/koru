# Test 906: Emitter Inline Flow Numbering Bug

## Purpose
Minimal reproduction of emitter bug where inline flow function calls reference the wrong `__inline_flow_N` functions.

## The Bug
When multiple procs have inline flows, the emitter generates globally numbered inline flow functions (`__inline_flow_1`, `__inline_flow_2`, etc.) but then incorrectly references them from different procs.

### What Should Happen
- `proc1` has inline flow → generates `__inline_flow_1(args: helper.Input)`
- `proc2` has inline flow → generates `__inline_flow_2(args: helper.Input)`
- `test_bug` calls proc1 → generates `__inline_flow_3(args: proc1.Input)`
- `test_bug` calls proc2 → generates `__inline_flow_4(args: proc2.Input)`

Then:
- Inside `proc1.handler`: call `__inline_flow_1(.{ .value = 10 })`
- Inside `proc2.handler`: call `__inline_flow_2(.{ .value = 20 })`
- Inside `test_bug.handler`: call `__inline_flow_3(.{})` and `__inline_flow_4(.{})`

### What Actually Happens
The emitter generates the inline flow functions correctly, but the **calls** inside proc handlers always use `__inline_flow_1`, `__inline_flow_2`, etc. in sequence, regardless of which numbered function they should actually call.

Result: `test_bug.handler` tries to call `__inline_flow_1()` with no arguments, but `__inline_flow_1` expects `helper.Input`.

## Expected Outcome
When this bug is fixed:
- Delete `compile_backend.err`
- Test will compile and run successfully
- Output will match `expected.txt`

## Related Tests
This bug also blocks:
- Test 208 (proc flow expression)
- Test 209 (proc implicit return)
- Test 210 (proc flow patterns)

All of those tests have the same emitter bug.
