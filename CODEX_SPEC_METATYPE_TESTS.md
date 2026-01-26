# Codex Specification: Fix Metatype Tests and Multi-Branch Tap Syntax

## Session Context

Previous session fixed BranchEnum keyword escaping in metatype bindings. This created 4 new PRIORITY tests to exercise metatype infrastructure. Two pass, two need fixes.

**Current Status:**
- 429 passing tests (up from 427)
- 2/3 metatype tests passing ✅
- 1 test blocked on AST issue
- 1 test not started

## Tasks

### Task 1: Fix 310_044 Metatype Binding Collision

**Priority:** HIGH - blocks metatype infrastructure verification
**Difficulty:** MEDIUM - requires understanding tap_transformer AST generation
**Time Estimate:** 1-2 hours investigation + 30 min implementation

**What's Wrong:**
Multiple metatype bindings of the same type in one tap get duplicate synthetic variable names:
```
Error: redeclaration of local constant '_profile_47182'
```

**Root Cause:**
`src/tap_transformer.zig` creates metatype_binding AST nodes with non-unique `.binding` field values.

**What to Do:**
1. Read `tests/regression/.../310_044_metatype_multiple_observers/INVESTIGATION.md` (complete analysis)
2. Find in `tap_transformer.zig:348` where metatype_binding nodes are created
3. Locate where `.binding` field is assigned (likely synthetic name generation)
4. Add counter/tracking to ensure unique names per metatype type
   - Example: `_profile_1`, `_profile_2` instead of `_profile_47182`, `_profile_47182`
5. Test with: `./run_regression.sh 310_044`
6. Should pass and generate unique variable names in output_emitted.zig

**Success Criteria:**
- Test 310_044 passes
- No "redeclaration" errors
- Generated code shows `_profile_1`, `_profile_2`, etc.

**Reference Files:**
- `src/tap_transformer.zig` (where to fix)
- `src/emitter_helpers.zig` (read-only, uses mb.binding)
- `koru_std/taps.kz` (tap system - working correctly)

---

### Task 2: Investigate 506 Multi-Branch Tap Syntax

**Priority:** MEDIUM - nice-to-have feature verification
**Difficulty:** LOW - exploration task, may reveal parser/emitter issues
**Time Estimate:** 30-45 min

**What to Test:**
Multi-branch tap syntax where one `~tap()` block has multiple handlers for same branch:
```koru
~tap(process -> *)
| success s |> log_success(result: s.result)
| success s |> audit_success(result: s.result)  // BOTH fire on success
| error e |> log_error(msg: e.msg)
```

**Contrast:**
Current verbose approach requires separate taps:
```koru
~tap(ring.dequeue -> *)
| value v |> process(data: v.data)
~tap(ring.dequeue -> *)
| value v when v.data * 2 > 2 |> process_timestwo(data: v.data)
```

**What to Do:**
1. Run: `./run_regression.sh 506`
2. Examine error messages to understand what's failing
3. Is it:
   - Parser issue (syntax not recognized)?
   - Emitter issue (code generation)?
   - Runtime issue (both handlers not firing)?
4. Add PRIORITY file with findings
5. Either fix or document as known limitation

**Success Criteria:**
- Test 506 passes, OR
- Clear documentation of what's blocking it (parser, emitter, runtime)

**Reference File:**
- `tests/regression/.../506_multi_branch_tap/input.kz` (test case)
- `tests/regression/.../506_multi_branch_tap/PRIORITY` (requirements)

---

### Task 3: Verify Metatype Tests Still Pass

**Priority:** CRITICAL - regression prevention
**Difficulty:** TRIVIAL - just run tests
**Time Estimate:** 5 min

**What to Do:**
```bash
./run_regression.sh 310_045 310_046
```

**Expected:**
Both should show ✅ PASS

**If Broken:**
1. Check if Task 1 accidentally broke these
2. Revert changes and try again more carefully
3. File separate PRIORITY for new issue

---

## Implementation Order

1. **Start with Task 1** - highest priority, unblocks metatype verification
2. **Then Task 2** - exploration task, may be quick
3. **Finally Task 3** - regression check before finishing

## Key Files Summary

### Core Metatype Infrastructure
- `koru_std/taps.kz` - Tap system (working ✅)
- `src/emitter_helpers.zig` - Code generation for metatypes (working ✅)
- `src/tap_transformer.zig` - AST generation (has bug 🐛)

### Tests
- `tests/regression/.../310_041_metatype_profile_binding/` - PASSING ✅
- `tests/regression/.../310_042_metatype_transition_binding/` - PASSING ✅
- `tests/regression/.../310_043_metatype_audit_binding/` - PASSING ✅
- `tests/regression/.../310_044_metatype_multiple_observers/` - FAILING 🔴
- `tests/regression/.../310_045_metatype_when_guards/` - PASSING ✅
- `tests/regression/.../310_046_metatype_enum_helpers/` - PASSING ✅
- `tests/regression/.../506_multi_branch_tap/` - TODO 🔵

## Important Notes

### DO NOT
- Don't try to fix the emitter (it's working correctly)
- Don't modify metatype struct definitions (they're in emitter_helpers for now)
- Don't spend time on 506 if Task 1 takes longer than expected

### DO
- Read the INVESTIGATION.md file before starting Task 1
- Run the full regression suite at the end: `./run_regression.sh --status`
- Commit each task separately with clear messages
- Document findings in PRIORITY files for any new issues discovered

## Testing Checkpoints

After each task, run:
```bash
./run_regression.sh --status | grep "passing\|failing"
```

Should see:
- After Task 1 fixed: 430+ passing (was 429)
- After Task 2: 430+ or 431+ depending on 506 fix
- After Task 3: No regressions

## Reference: BranchEnum Keyword Escaping (Already Fixed)

For context, the previous session fixed keyword escaping in metatype bindings:
- Issue: `.error` is invalid Zig (reserved word)
- Fix: `.@"error"` is valid (escaped)
- Location: `emitter_helpers.zig` lines 2080-2088, 5145-5150
- Uses: `codegen_utils.needsEscaping(mb.branch)`

This is working correctly and enabled the metatype tests to compile.

---

## Good Luck!

All investigation work is documented. You have clear starting points and success criteria.
The fix for 310_044 is straightforward once you find where the synthetic names are generated.
Questions? Check INVESTIGATION.md or the test files themselves.
