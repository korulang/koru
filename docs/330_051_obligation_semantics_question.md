# Phantom Obligation Semantics: Union Consume Marker — Open Question

**Test in question:** `330_051_union_with_consume_marker`
**Status:** FAILING — compiler emits a double cleanup call
**Question:** Is the test's intended behavior semantically correct, or is the test itself wrong?

---

## Background: How Phantom Obligations Work (passing cases)

Koru phantom types track resource lifecycle at compile time.

### Producing an obligation: `[state!]` suffix on output

```koru
~pub event open { path: []const u8 }
| opened { file: *File[opened!] }   // ← ! suffix: caller MUST clean this up
```

### Consuming an obligation: `[!state]` prefix on input

```koru
~pub event close { file: *File[!opened] }  // ← ! prefix: this discharges the obligation
| closed {}
```

### Usage — the simple, working case (test 330_005)

```koru
~app.fs:open(path: "test.txt")
| opened f |> app.fs:close(file: f.file)   // obligation discharged here
    | closed |> _
```

Output:
```
Opening file: test.txt
Closing file
```

The obligation is created on binding `f.file` when `open` returns. It is discharged when `close(file: f.file)` is called — same binding, exact state match (`opened!` discharged by `[!opened]`).

---

## The Failing Test (330_051)

### Library module (`handle.kz`)

```koru
~pub event open {}
| opened { h: *Handle[opened!] }        // produces opened! obligation

~pub event start_close { h: *Handle[opened] }  // takes opened (no !)
| closing { h: *Handle[closing] }               // transitions to closing, no new obligation

~pub event finalize { h: *Handle[!opened|closing] }  // ← THIS IS THE QUESTION
| done {}
```

**Key:** `finalize` accepts a handle in EITHER `opened` OR `closing` state, with the `!` prefix.

### Test program (`input.kz`)

```koru
// Flow 1: direct finalize from opened state
~app.handle:open()
| opened h1 |> app.handle:finalize(h: h1.h)
    | done |> _

// Flow 2: transition to closing, then finalize
~app.handle:open()
| opened h1 |> app.handle:start_close(h: h1.h)
    | closing h2 |> app.handle:finalize(h: h2.h)
        | done |> _
```

### Expected output (what a human would expect)

```
Opening handle
Finalizing handle: 42
Opening handle
Starting close: 42
Finalizing handle: 42
```

### Actual output (what the compiler generates)

```
Opening handle
Finalizing handle: 42
Opening handle
Starting close: 42
Finalizing handle: 42
Finalizing handle: 42   ← EXTRA: compiler auto-discharged h1's obligation
```

---

## What the Compiler Does (the bug path)

The obligation tracker stores obligations by **binding name**:

1. `open()` → obligation stored as `"h1.h" → {state: "opened!"}` ✓
2. `start_close(h: h1.h)` — no `!` on its `h` parameter → obligation on `"h1.h"` **not cleared**
3. `| closing h2 |>` → `h2.h` is created with state `"closing"`, no `!` → no new obligation
4. `finalize(h: h2.h)` with `[!opened|closing]` → tries `clearObligation("h2.h")` → **not found** (obligation is still on `"h1.h"`)
5. At terminal `_`: obligation `"h1.h"` is still live → **auto-discharge fires** → inserts `finalize(h1.h)` → double call

The root cause: obligation is keyed to the binding name at creation time (`h1.h`). After `start_close` transitions the handle to `h2.h`, the obligation doesn't follow.

---

## The Two Interpretations

### Interpretation B: `!` applies to the entire union

> `[!opened|closing]` means: "this event discharges the cleanup obligation for a handle that is currently in EITHER the `opened` OR `closing` state."

Under B, when the handle transitions `opened → closing` via `start_close` (no `!`), the `opened!` obligation **travels with the resource identity** to the new binding. Calling `finalize(h: h2.h)` (with h2 in `closing` state) discharges the original `opened!` obligation.

**Requires:** the compiler to transfer obligations through state transitions — when `start_close(h: h1.h)` produces `h2.h` with the same field name `h`, the obligation moves from `h1.h` to `h2.h`.

**The fix in auto_discharge_inserter.zig:** add a "pending transfer" mechanism: when a non-`!` event has the same field name in input and output, record the obligation transfer so the new binding inherits it.

### Interpretation C: `!` applies only to the members that carry it — explicit obligation at each step

> `[!opened|closing]` only discharges an obligation when the handle is in `opened` state. The `closing` member carries no `!`, so calling `finalize` with a `closing` handle discharges nothing.

Under C, the correct module design would be:

```koru
~pub event start_close { h: *Handle[!opened] }  // ← explicitly discharges opened!
| closing { h: *Handle[closing!] }               // ← and creates a new closing! obligation

~pub event finalize { h: *Handle[!closing] }     // ← discharges closing!
| done {}
```

Or alternatively, keep `finalize` able to handle both, but make the obligations explicit:
```koru
~pub event finalize { h: *Handle[!opened|!closing] }  // ! on each member separately
| done {}
```

Under C, the current test is **incorrectly designed**: `start_close` should have `!opened` on its input to discharge the obligation before creating the `closing!` state.

---

## The Semantic Question

**Is it valid for `[!opened|closing]` to discharge an obligation when the handle is in `closing` state, given that the obligation was originally created as `opened!`?**

Arguments **for B**:
- The resource still needs cleanup regardless of which intermediate state it's in
- The union `[!opened|closing]` expresses "I handle cleanup for this resource in either state"
- This is ergonomic: library authors can write one cleanup function for multiple states without forcing callers to track which state they're in
- `finalize` at runtime does the same thing regardless of state — the phantom state is erased

Arguments **for C**:
- The `!` marker in `[!state]` means "I discharge the obligation for state `state`" — `closing` is not `opened`, so it shouldn't discharge `opened!`
- It's semantically cleaner: each state that requires cleanup carries its own `!`
- The existing model (obligation keyed by binding, discharged by exact `!state` match) already handles C correctly with no implementation changes
- B requires the compiler to infer resource identity across state transitions — a significant complexity increase
- B's "obligation travels with the resource" is an implicit contract that's hard to reason about

---

## The Passing Tests on Either Side

**Tests that work unambiguously (neither B nor C needed):**
- 330_005, 330_006, 330_008: direct open → close, no intermediate state transitions
- 330_027_db: two separate obligations (connection + transaction), no state transitions
- 330_050: union state acceptance WITHOUT obligations (no `!` at all)

**Tests that require B to work as written:**
- 330_051 (this one — currently failing)

**Tests that suggest C is the intended design:**
- All other tests model obligations as direct state-to-state discharge with no intermediate transitions

---

## The Question for External Review

1. Is Interpretation B semantically sound? Should `[!opened|closing]` discharge an `opened!` obligation when the handle is currently in `closing` state?

2. If B is correct: the fix is a "pending transfer" mechanism in the obligation tracker (~30 lines in `auto_discharge_inserter.zig`). Is this the right implementation?

3. If C is correct: the test (`handle.kz`) should be redesigned so that `start_close` explicitly discharges the `opened!` obligation and creates `closing!`, and `finalize` takes `[!closing]`.

4. Is `[!opened|closing]` as written even meaningful? Or should it be `[!opened|!closing]` (each member has its own `!`) if we want "discharge from either state"?

---

## Passing Test Reference

All 19 other tests in `330_PHANTOM_TYPES` currently pass. They test:
- Basic obligation satisfaction (330_001 through 330_008)
- Auto-discharge with single/multiple resources (330_011 through 330_021)
- Auto-discharge in if/for branches (330_022 through 330_030)
- Scope-aware auto-discharge (330_032, 330_053, 330_054, 330_055)
- Default discharge annotation `[!]` (330_027_default_discharge_annotation, 330_035, 330_036, 330_037)
- Union state acceptance without obligations (330_050)

The ONLY failing test is 330_051.
