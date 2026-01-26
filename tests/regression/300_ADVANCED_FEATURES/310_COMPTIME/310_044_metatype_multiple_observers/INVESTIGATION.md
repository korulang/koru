# Investigation: Metatype Binding Variable Collision

## Problem Statement

Test 310_044 fails with:
```
Error: output_emitted.zig:58:15: error: redeclaration of local constant '_profile_47182'
    const _profile_47182 = taps.Profile{
           ^~~~~~~~~~~~~~
```

When a single `~tap()` declaration has multiple metatype bindings of the same type:
```koru
~tap(hello -> *)
| Profile p |> logger(msg: p.source)
    | done |> _
| Profile p2 |> logger(msg: p2.source)
    | done |> _
```

Both Profile bindings attempt to use the same synthetic variable name `_profile_47182`.

## Root Cause Analysis

### Investigation Path

1. **Initial Hypothesis (WRONG):** The emitter generates the same synthetic name
   - Investigated `src/emitter_helpers.zig` where metatype_binding code is emitted
   - Found TWO emission locations: lines 2027-2130 and 5091-5195
   - Attempted scope block wrapping to isolate collisions
   - Result: Scope blocks didn't work because continuations need to be in same scope as binding
   - **Lesson:** Understand the full AST flow before trying emitter fixes

2. **Real Problem (CONFIRMED):** AST already has duplicate names
   - Generated output shows `const _profile_47182 = taps.Profile{` for BOTH bindings
   - These names come from the AST's `metatype_binding.binding` field
   - The emitter just reads `mb.binding` and uses it as-is
   - So the collision happens BEFORE the emitter sees the code

### Where Synthetic Names Are Generated

The AST generation happens in:
- **Most likely:** `src/tap_transformer.zig` line 348 (`.metatype_binding => |mb|`)
  - This is where tap patterns are transformed into AST nodes
  - This is where metatype_binding nodes are created
  - The `.binding` field is assigned here

- **Possibly:** Another AST transformation pass that creates or modifies metatype_binding nodes
  - Search: `metatype_binding` across all .zig files
  - Check: Any place that assigns to `mb.binding` or creates metatype_binding structs

## Solution Design

### Approach
When multiple metatype_binding steps of the same type appear in sequence within a single tap handler, each needs a UNIQUE synthetic variable name.

### Implementation Steps

1. **Find the binding name assignment** in tap_transformer.zig
   - Likely around line 348 where metatype_binding nodes are created
   - Look for code that generates `_profile_*`, `_transition_*`, `_audit_*` names

2. **Add counter/tracking mechanism**
   - Track how many Profile/Transition/Audit bindings have been created in the current context
   - Suffix: `_profile_1`, `_profile_2`, etc. instead of reusing `_profile_47182`
   - Or use hash-based unique IDs if available in the codebase

3. **Ensure scope isolation** (separate concern)
   - Each metatype binding should have its continuation in the same lexical scope
   - This prevents outer scope access issues
   - Currently continuations may be emitted outside binding scope

### Code Locations to Modify

1. **Primary:** `src/tap_transformer.zig:348`
   - Find where `metatype_binding` union value is constructed
   - Identify where `.binding` field gets its value
   - Implement unique naming for duplicate types

2. **Secondary:** `src/emitter_helpers.zig` (already attempted)
   - Lines 2027-2130: metatype_binding in `emitSubflowContinuationsWithDepth`
   - Lines 5091-5195: metatype_binding in `emitStep`
   - Both emit from `mb.binding` - this is read-only from emitter perspective
   - No changes needed here once AST is fixed

## Test Cases to Verify

### 310_044: Multiple metatype observers
```koru
~tap(hello -> *)
| Profile p |> logger(msg: p.source)
| Profile p2 |> logger(msg: p2.source)
```
**Expected:** Both observers fire, no redeclaration error

### 310_045: Profile observers (PASSING ✅)
```koru
~tap(hello -> *)
| Profile p |> logger(msg: p.source)
```
**Current:** Works fine - single binding per type

### 310_046: Transition observers (PASSING ✅)
```koru
~tap(process -> *)
| Transition _ |> logger(msg: "transition")
```
**Current:** Works fine - single binding per type

## Success Criteria

- [ ] Test 310_044 passes
- [ ] Generated code has unique variable names: `_profile_1`, `_profile_2`, etc.
- [ ] No "redeclaration" errors
- [ ] All three metatype tests (310_044, 310_045, 310_046) passing
- [ ] Regression suite still passes (429+ tests)

## Related Issues

### 506: Multi-branch tap syntax
Separate issue - tests if multiple handlers in one tap block work correctly:
```koru
~tap(process -> *)
| success s |> log_success(result: s.result)
| success s |> audit_success(result: s.result)  // TWO handlers for success
| error e |> log_error(msg: e.msg)
```
Status: TODO - not yet investigated

## Notes for Codex

1. **Don't fix the emitter** - the problem is in AST generation
2. **Start in tap_transformer.zig** - that's where metatype_binding nodes are created
3. **Search for where `.binding` field is assigned** - that's where unique names are generated
4. **Look for existing naming patterns** - the codebase may already have a counter/unique ID system
5. **Run 310_044 after fix** - quick feedback on whether the solution works
6. **Consider scope blocks as a follow-up** - once variable names are unique, might want to wrap each binding in scope for cleaner isolation
