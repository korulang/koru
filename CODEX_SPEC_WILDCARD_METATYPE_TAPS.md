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

## Root Cause Analysis

### Key Difference: Concrete vs Wildcard Patterns

**Concrete Pattern (working - 310_044):**
```koru
~tap(hello -> *)
| Profile p |> logger(msg: p.source)
```
- Pattern matches specific event: `hello`
- Binding name rewriting happens: `p` → `_profile_0`
- Generated variable: `const _profile_0 = taps.Profile{...}`

**Wildcard Pattern (broken - 510_070):**
```koru
~tap(* -> *)
| Profile p |> logger(msg: p.source)
```
- Pattern matches all events via glob
- Binding name rewriting **MAY NOT BE HAPPENING** for wildcard matches
- Generated variable references `p` (original name) instead of `_profile_N`
- Scope block closes before continuation executes

### Two Possible Issues

**Issue A: Binding Name Rewriting Failure**
- For wildcard patterns, the `tap_binding` parameter in `tap_transformer.zig` might be null
- Without `tap_binding`, the rewrite logic (`rewriteStepBinding`) doesn't run
- Original binding name `p` stays in AST unchanged
- But variable declared as `_profile_0` - name mismatch!

**Issue B: Scope Block Wrapping Problem**
- Even if rewriting works, scope blocks (lines 4922-4943 in `emitter_helpers.zig`) isolate metatype bindings
- Continuations emitted AFTER scope block closes
- Binding `_profile_0` is out of scope when continuation tries to use it

## Solution Design

### Investigation Phase (Quick)

**For Codex to discover:**
1. Check if wildcard patterns have `tap_binding` (original binding name) or if it's null
2. Print AST before/after binding rewrite to see if names actually change
3. Check if scope blocks are being applied to wildcard taps
4. Verify if binding rewrite is even being called for wildcard patterns

### Fix Options

**Option 1: Fix Binding Rewriting for Wildcards** (likely correct)
- Ensure `tap_binding` is properly extracted for wildcard patterns in tap_transformer
- Verify `rewriteStepBinding` is called with correct parameters
- Test that binding name rewriting works for all pattern types

**Option 2: Remove Scope Block Wrapping** (if necessary)
- Revert lines 4922-4943 in emitter_helpers.zig
- Rely on counter-based unique naming (already works)
- Verify 310_044 still passes without scopes

**Option 3: Move Continuations Inside Scope** (proper fix)
- Keep scope block wrapping
- Ensure continuations are emitted INSIDE the scope, not after
- Requires understanding how continuations are structured in emitter

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
   - Add debug output to tap_transformer to show tap_binding values for each pattern type
   - Compare concrete patterns vs wildcard patterns
   - Check if binding rewriting is being called

2. **Apply Fix** (30-60 min depending on root cause)
   - Option 1 if binding rewriting isn't happening
   - Option 2 if scopes are the issue
   - Option 3 if structure changes needed

3. **Verify All Tests Pass** (10 min)
   ```bash
   ./run_regression.sh 310_044 310_045 310_046 510_070 510_071 510_072
   ```

## Key Files Summary

### Core Infrastructure
- `koru_std/taps.kz` (lines 114-150) - `pathMatches()` function for pattern matching
- `koru_std/taps.kz` (lines 360-410) - Binding rewriting logic (`rewriteStepBinding`)
- `koru_std/taps.kz` (lines 366-380) - Metatype binding counter and name synthesis
- `src/emitter_helpers.zig` (lines 4922-4943) - Scope block wrapping for metatype_binding

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
- Add debug output to understand why binding rewriting differs for wildcards
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
