## Resolution on Obligation Semantics: 330_051

After reviewing the document `330_051_obligation_semantics_question.md` and discussing the semantics, we have reached a strong consensus: **Interpretation C (Explicit Discharge with Explicit Union Members) is the correct and desired pattern for Koru.**

The alternative, Interpretation B (implicitly transferring obligations based on field names), was rejected because it introduces fragile heuristics, "invisible magic" that is hard to debug, and breaks the local reasoning of the type system.

### Why Interpretation C Wins
1.  **Zero Compiler Magic:** The existing rule (obligations are keyed by binding and discharged by an exact `!state` match) remains pure and robust. We do not need to implement complex "pending transfer" mechanisms or alias analysis.
2.  **Self-Documenting APIs:** The contract is explicit. When a state transition occurs that transfers ownership/lifecycle responsibilities, it is clearly visible in the type signature.
3.  **Syntactic Clarity:** The syntax `[!opened|!closing]` explicitly states that the function can consume *either* the `opened!` obligation OR the `closing!` obligation. It distributes the meaning precisely.

### The Problem with 330_051
Currently, `330_051_union_with_consume_marker/handle.kz` expects the compiler to magically track the `opened!` obligation across a state transition into `closing` without explicitly consuming it.

```koru
// CURRENT (Incorrect) DESIGN
~pub event start_close { h: *Handle[opened] }  // Read-only borrow; DOES NOT consume opened!
| closing { h: *Handle[closing] }              // Produces no new obligation

~pub event finalize { h: *Handle[!opened|closing] } // Ambiguous/Incorrect syntax for "discharge either"
| done {}
```

Because `start_close` does not consume the `opened!` obligation, that obligation remains attached to the original `h1.h` binding. Thus, when the test ends, the auto-discharge inserter correctly inserts a double-call to `finalize(h1.h)`.

### The Required Fix (Option 2)

The correct pattern in Koru for state transitions that carry an obligation is **Option 2**: explicitly consume the old obligation and explicitly produce a new one.

We need you to implement this pattern by updating the library module `handle.kz` in the test `330_051`.

**Update `handle.kz` to:**

```koru
~pub event open {}
| opened { h: *Handle[opened!] }

// Explicitly consume the 'opened!' obligation, and explicitly produce a new 'closing!' obligation.
~pub event start_close { h: *Handle[!opened] }  
| closing { h: *Handle[closing!] }               

// Explicitly define that we can discharge EITHER the 'opened!' OR the 'closing!' obligation.
~pub event finalize { h: *Handle[!opened|!closing] } 
| done {}
```

With this change, the test program (`input.kz`) will function exactly as intended without any changes to the compiler's current obligation tracking logic:

```koru
// Flow 1: Direct finalize
~app.handle:open()
| opened h1 |> app.handle:finalize(h: h1.h) // Discharges opened!
    | done |> _

// Flow 2: Transition then finalize
~app.handle:open()
| opened h1 |> app.handle:start_close(h: h1.h) // Discharges opened!, produces closing! on h2
    | closing h2 |> app.handle:finalize(h: h2.h) // Discharges closing!
        | done |> _
```

### Next Steps for Implementation
1.  **Do not modify** the obligation tracker in `auto_discharge_inserter.zig` to add heuristical obligation transfers.
2.  **Rewrite** `tests/regression/330_PHANTOM_TYPES/330_051_union_with_consume_marker/handle.kz` to use the explicit `[!opened]` consumption and `[closing!]` production pattern shown above.
3.  Ensure the `finalize` event uses the specific `[!opened|!closing]` syntax to indicate it can discharge either state.
4.  Run the test to confirm it now passes with the compiler's existing pure logic.
