## ACTUAL ROOT CAUSE (Updated Analysis!)

**Original hypothesis:** Related to self-loop via labels (`@consume` → `#consume`)

**WRONG!** Test 916 has the EXACT SAME self-loop pattern and it WORKS! ✅

## The Real Bug

**The tap is not being collected/generated AT ALL!**

Compare to test 916 (which works):

**Test 916 tap (line 93):**
```koru
~tap(ring.dequeue -> *) | value v |> process(data: v.data)
```
→ Generates `__tap0()` function and invokes it! ✅

**Test 914 tap (line 85-86):**
```koru
~tap(ring.dequeue -> *) | value v when v.data % 2 == 0 |> process(data: v.data)
    | done |> _
```
→ NO tap functions generated! ❌

## The Difference

**Test 916:** Tap has NO continuation after `process` (implicit terminal)

**Test 914:** Tap has continuation `| done |> _` after `process`

**Hypothesis:** The tap collector fails when the tap continuation has its own continuation!

See `BAD_CODE_ANALYSIS.md` for what SHOULD be generated.