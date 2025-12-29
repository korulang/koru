# BUG: Taps With When Clauses Not Collected in Label Loops

## Status: FRONTEND/PARSER BUG (Not code generation)

The when clause code generation bug has been FIXED (tests 609 and 915 pass).

However, test 914 exposes a DIFFERENT bug: taps with when clauses on label loop events are not being collected at all.

## Current (WRONG) Behavior:

```
Produced 6 values
```

No processing happens - the tap never fires.

## Expected (CORRECT) Behavior:

```
Produced 6 values
Processing: 0
Processing: 2
Processing: 4
```

Only even numbers are processed (filtered by when clause).

## The Tap Definition:

```koru
~ring.dequeue -> *
| value v when v.data % 2 == 0 |> process(data: v.data)
    | done |> _
```

This tap should:
1. Observe `ring.dequeue` events
2. Filter for `.value` branch where `v.data` is even
3. Call `process(data: v.data)` for matching events

## What's Happening:

The tap is not being collected/registered during AST processing. Looking at the generated code, there's no `__tap0` function at all.

## Root Cause:

Frontend/parser issue - taps with when clauses in certain contexts (possibly label loops or specific event patterns) are being treated as subflows instead of event taps during AST construction.

## Related Tests:

- ✅ Test 609: When clauses work (simple flow, no labels)
- ✅ Test 915: When clauses work (simple flow, no labels)
- ✅ Test 913: Taps work in label loops (no when clause)
- ❌ Test 914: Taps with when clauses in label loops (THIS BUG)

## Fix Location:

This needs to be fixed in the FRONTEND (parser/AST builder), not in code generation. The code generation is now correct (as proven by tests 609 and 915 passing).

## Workaround:

None - the tap simply doesn't fire. This is a blocking bug for using when clauses with label loop events.
