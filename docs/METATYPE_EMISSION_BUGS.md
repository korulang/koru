# Metatype Emission: Known Issues & Investigation Guide

## Status: NEEDS INVESTIGATION

The emission of metatype branches (Profile, Audit, Transition) in tap continuations has several bugs. This document captures what we know and provides a starting point for fixes.

## The Bugs

### 1. Metatype Bindings Not Added to Scope

**Test:** `330_042_metatype_binding_scope`

When you write:
```koru
~tap(work -> *)
| Profile p |> std.io:print.ln("Profile: {{p.source}}.{{p.branch}}")
```

The emitter generates:
```zig
const _profile_0 = taps.Profile{
    .source = "input:work",
    .branch = "done",
    ...
};
_ = &_profile_0;
@import("std").debug.print("Profile: {any}.{any}\n", .{p.source, p.branch});
//                                                     ^ 'p' is undeclared!
```

**Problem:** The binding `p` is never mapped to `_profile_0`. The emitter creates the profile struct but doesn't add the user's binding name to scope.

**Workaround:** Passing bindings as event arguments works:
```koru
| Profile p |> log(source: p.source, branch: p.branch)
    | done |> _
```
This path correctly substitutes `p` with `_profile_0`.

### 2. Missing Binding Validation

**Test:** `310_034_metatype_branch_requires_binding`

This should be rejected:
```koru
| Transition |> logger()  // Missing binding!
```

Should require:
```koru
| Transition t |> logger()   // or
| Transition _ |> logger()   // if discarding
```

**Problem:** The parser doesn't know about metatypes. The shape checker validates bindings against event definitions, but metatype branches are injected by the emitter during tap expansion - they bypass shape checking entirely.

**Fix needed:** The emitter should validate that metatype branches have proper bindings when it injects them.

## Where to Look

The metatype emission likely happens in:
- `src/visitor_emitter.zig` - main emission logic
- Look for where `_profile_0`, `taps.Profile`, `taps.Audit`, `taps.Transition` are generated
- The tap transform in `koru_std/taps.kz` may also be involved

## Key Questions

1. **Where does binding substitution happen?** Why does it work for event arguments but not string interpolation?

2. **Where are metatype branches injected?** This is where validation should be added.

3. **Is there a scope/binding map for tap continuations?** The user's binding name needs to be registered.

## Test Cases

Run these to verify fixes:

```bash
./run_regression.sh 330_042   # Metatype binding scope (currently fails)
./run_regression.sh 310_034   # Missing binding validation (currently TODO)
./run_regression.sh 330_010   # Module wildcard + Audit (currently fails)
./run_regression.sh 330_009   # Universal wildcard + Profile (passes - uses workaround)
```

## Related Working Code

`330_009_universal_wildcard_metatype` passes because it uses event arguments:
```koru
| Profile p |> log(source: p.source, branch: p.branch)
```

Compare the emission paths between this working case and the failing string interpolation case.
