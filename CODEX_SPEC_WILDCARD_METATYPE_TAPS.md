# Codex Specification: Fix Wildcard Metatype Tap Binding Scope

## Session Context

Previous session fixed metatype binding collision issues (310_044). This uncovered THREE related failures with wildcard pattern metatype taps (510_070, 510_071, 510_072).

**Current Status:**
- 430 passing tests (up from 427)
- 3/3 metatype concrete-pattern tests passing ✅
- 3/3 metatype wildcard-pattern tests FAILING 🔴 (same root cause)
- All failing with: `error: use of undeclared identifier 'p'`

## The Problem

When metatype taps use wildcard patterns, the generated Zig code loses access to the binding variable:

```zig
// Generated code for 510_070:
{
    const _profile_0 = taps.Profile{ ... };
}
const result_2 = main_module.logger_event.handler(.{ .msg = p.source });
                                                          ^ ERROR: p not in scope
```

The binding variable `p` is out of scope when the continuation tries to use it.

## Observations (Ground Truth So Far)

- The active transform is `koru_std/taps.kz` (not `tap_transformer.zig`).
- Transform logs show binding rewrite *does* run for wildcard taps:
  - `Metatype binding 'p' → '_profile_N'`
- Emitted Zig still shows `p.source` in wildcard tap handlers.
- Tap registry + Profile metatype should always use canonical event names (module-qualified), even when invocations are written locally.
- The unqualified call `logger(msg: p.source)` resolves to `module_qualifier = "input"` with segment `logger`.
  - The imported module defines `log`, not `logger`.
  - This may be a separate test validity issue or a missing resolution rule.

## Revised Root Cause Hypotheses

### Hypothesis 0: Tap-on-tap splicing (most likely)
- There are two taps active in these tests: the one in `input.kz` and the one in `test_lib/logger.kz`.
- The logger tap wraps the `~tap(...)` flow itself (source event becomes `std.taps:tap` or module-local `tap`).
- That splice injects the *other* tap’s handler into runtime flows **before** the metatype binding exists.
- Result: `p.source` appears in emitted Zig without a `const _profile_N`, causing the undefined identifier error.

### Hypothesis A: Rewrite runs but doesn’t stick in the transformed AST
- `rewriteStepBinding` executes, but the rewritten step is not the one that ends up in the final continuation tree.
- Possible causes:
  - `wrapContinuation` constructs a rewritten step but later reuses the original tap continuation node.
  - A later transform pass replaces the rewritten step with an older copy.

### Hypothesis B: Rewrite misses the representation actually emitted
- `rewriteStepBinding` only edits `arg.value`.
- If emission uses `arg.expression_value.text`, it will still emit `p.source`.
- Need to confirm which field is used for `msg` in the transformed AST.

### Hypothesis C: The tap handler invocation is invalid
- The call `logger(...)` may be wrong if Koru requires qualified paths.
- Even with `p` fixed, the test might still be invalid unless `logger` resolves.

## Solution Design

### Investigation Phase (Quick)

**Next checks (order matters):**
1. Inspect the *transformed AST* for the inserted tap handler and confirm whether the arg is `p.source` or `_profile_N.source`.
2. Add temporary debug prints in `wrapContinuation` to log tap step args before/after `rewriteStepBinding`.
3. Confirm whether emission uses `arg.value` or `arg.expression_value.text` for this field.
4. Decide whether unqualified `logger(...)` is valid Koru (test may be wrong).

### Fix Options (Conditional)

**Option 0: Prevent taps from wrapping tap declarations**
- Skip flows whose invocation is `tap` (the transform event) when applying taps.
- This prevents tap-on-tap splicing and removes the `p.source` leak.
- Open question: should this be limited to `std.taps:tap` only?

**Option 1: Ensure rewrite lands in the AST**
- If the transformed AST still has `p.source`, fix the transform to use the rewritten step.
- Likely in `koru_std/taps.kz` (wrap/splice path).

**Option 2: Rewrite expression payloads too**
- If the arg uses `expression_value.text`, extend rewrite to update that field.

**Option 3: Clarify unqualified invocation**
- If `logger(...)` is invalid, update the test to use the correct qualified event name.

## Test Cases

### 510_070: Universal Wildcard (`* -> *`)
```koru
~tap(* -> *)
| Profile p |> logger(msg: p.source)
    | done |> _

~hello()    // Should fire tap: "[TAP] input:hello"
| done |> goodbye()
```
Expected output: `[TAP] input:hello\nHello\n[TAP] input:goodbye\nGoodbye\n`

### 510_071: Module Wildcard (`input:* -> *`)
```koru
~tap(input:* -> *)
| Profile p |> logger(msg: p.source)
    | done |> _

~hello()    // Should fire tap: "[TAP] input:hello"
| done |> goodbye()
```
Expected output: `[TAP] input:hello\nHello\n[TAP] input:goodbye\nGoodbye\n`

### 510_072: Event Wildcard (`*:compute -> *`)
```koru
~tap(*:compute -> *)
| Profile p |> logger(msg: p.source)
    | done |> _

~compute(x: 42)  // Should fire tap: "[TAP] input:compute"
| result |> _
```
Expected output: `[TAP] input:compute\n`

### Reference: Working Concrete Pattern (310_044)
```koru
~tap(hello -> *)
| Profile p |> logger(msg: p.source)
    | done |> _
| Profile p2 |> logger(msg: p2.source)
    | done |> _
```
Status: PASSING ✅ - Use as reference for how binding rewriting SHOULD work

## Implementation Order

1. **Debug Investigation** (20-30 min)
   - Add debug output in `koru_std/taps.kz` around `wrapContinuation`.
   - Confirm the transformed AST contains the rewritten binding.
   - Verify whether `arg.value` or `arg.expression_value.text` is emitted.

2. **Apply Fix** (30-60 min depending on root cause)
   - Option 1 if the rewritten step is lost.
   - Option 2 if expression payloads aren’t rewritten.
   - Option 3 if `logger(...)` is invalid and the test must be corrected.

3. **Verify All Tests Pass** (10 min)
   ```bash
   ./run_regression.sh 310_044 310_045 310_046 510_070 510_071 510_072
   ```

## Key Files Summary

### Core Infrastructure
- `koru_std/taps.kz` (lines 114-150) - `pathMatches()` function for pattern matching
- `koru_std/taps.kz` (lines 360-410) - Binding rewriting logic (`rewriteStepBinding`)
- `koru_std/taps.kz` (lines 366-380) - Metatype binding counter and name synthesis
- `koru_std/taps.kz` (lines 290-520) - `wrapContinuation` and metatype binding insertion

### Tests
- `310_044_metatype_multiple_observers/` - PASSING ✅ (reference)
- `510_070_universal_wildcard_concrete/` - FAILING 🔴
- `510_071_module_wildcard_concrete/` - FAILING 🔴
- `510_072_event_wildcard_concrete/` - FAILING 🔴

## Success Criteria

- [ ] Test 510_070 passes
- [ ] Test 510_071 passes
- [ ] Test 510_072 passes
- [ ] All three generate correct output
- [ ] Tests 310_044, 310_045, 310_046 still pass (no regressions)
- [ ] No new failures in regression suite

## Testing Checkpoints

After fix:
```bash
./run_regression.sh --status | grep "passing\|failing"
```

Should see:
- After fix: 433 passing (430 + 3 wildcard tests fixed)
- No new failures introduced

## Important Notes

### DO
- Add debug output in `koru_std/taps.kz` to confirm the rewritten step is used
- Run 310_044 frequently to ensure it doesn't break
- Test all three wildcard patterns - they're similar but with different pattern types
- Document findings in this spec file before implementing

### DON'T
- Remove the counter-based unique naming (it's working correctly)
- Change metatype struct definitions in emitter_helpers
- Modify core pattern matching logic without understanding it first

## Reference: How Concrete Patterns Work (Already Fixed)

For reference, here's what works in 310_044:
1. Pattern `hello -> *` matches concrete event
2. Tap binding extracted: `p` (the identifier after `Profile`)
3. Synthetic name generated: `_profile_0`, `_profile_1`, etc.
4. Binding rewriting: all references to `p` → `_profile_N`
5. Generated code: `const _profile_0 = taps.Profile{...}`
6. Continuation uses: `logger(msg: _profile_0.source)` ✅

---

## Good Luck!

This should be straightforward once we understand why binding rewriting differs for wildcard vs concrete patterns. The fix likely involves ensuring the tap_binding parameter is properly populated for all pattern types.

Questions? Debug output will tell the story!
