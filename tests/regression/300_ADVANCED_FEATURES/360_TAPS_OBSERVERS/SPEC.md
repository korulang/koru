# Taps & Observers Specification

> Read-only event observation for logging, metrics, and debugging.

📚 **[Back to Main Spec Index](../../../SPEC.md)**

**Last Updated**: 2026-02-15
**Test Range**: 501-507

---

## What Are Event Taps?

Event Taps observe event transitions without interfering with the main flow. They enable:
- **Logging**: Track event execution
- **Metrics**: Measure performance
- **Debugging**: Trace program flow
- **Auditing**: Record security events

**Key Properties**:
- Read-only observers - cannot modify data or return values
- Multiple taps execute independently (order doesn't affect correctness)
- Not required to be exhaustive (can observe only specific branches)
- Compile to zero-cost inlined code at transition points

---

## Basic Syntax

Event Taps use `~tap()` with `->` to indicate observation direction:

```koru
~tap(source_event -> destination_event)
| branch binding |> action
```

**Example**:
```koru
// Observe file.read errors
~tap(file.read -> *)
| error e |> log.error("File read failed:", e.msg)
```

See: [603_event_taps](../603_event_taps/)

---

## Wildcard Patterns

### Wildcard Destination

Observe all outputs from a specific event:

```koru
~tap(source_event -> *)
| branch binding |> action
```

**Example**:
```koru
// Log all outcomes from authentication
~tap(auth.check -> *)
| success u |> log.info("Login success:", u.username)
| failure f |> log.warn("Login failed:", f.reason)
```

### Wildcard Source

Observe all transitions to a specific event:

```koru
~tap(* -> destination_event)
| transition t |> action
```

**Example**:
```koru
// Track all calls to send_email
~tap(* -> send_email)
| transition t |> metrics.increment("emails_sent")
```

### Universal Tap

Observe ALL event transitions:

```koru
~tap(* -> *)
| transition t |> profiler.record(t)
```

**Example**:
```koru
// Universal profiling
~tap(* -> *)
| transition t |> latency.measure(t.source, t.dest, t.duration_ns)
```

See: [605_wildcard_patterns](../605_wildcard_patterns/)

---

## Transition Metatype

When using wildcard sources (`~tap(* -> ...)`), the shape is unknown at parse time. Use the `transition` metatype to access metadata:

```koru
pub const Transition = struct {
    source: []const u8,      // Source event name
    dest: []const u8,        // Destination event name
    branch: []const u8,      // Branch name taken
    duration_ns: u64,        // Execution time
    // Additional metadata...
};
```

**Usage**:
```koru
~tap(* -> database.query)
| transition t |> profiler.record(
    source: t.source,
    duration: t.duration_ns
)
```

See: [608_transition_metatype](../608_transition_metatype/)

---

## Annotations

Taps support annotations for conditional compilation:

> **NOTE**: Annotation placement on taps is not yet verified by tests. Syntax below follows the `~[ann] keyword(...)` pattern used elsewhere (e.g., `~[opaque] event`).

```koru
~[annotation] tap(source_event -> destination_event)
| branch binding |> action
```

### Common Annotations

**Debug-only taps**:
```koru
~[debug] tap(* -> *)
| transition t |> log.trace(t)
```

**Profiling taps**:
```koru
~[profile] tap(auth.check -> *)
| result r |> metrics.record(r)
```

**Production logging**:
```koru
~[production] tap(* -> database.query)
| error e |> alert.send("DB error:", e)
```

See: [602_annotation_syntax](../602_annotation_syntax/)

---

## Non-Exhaustive Matching

Unlike regular flows, taps don't need to handle all branches:

```koru
// Only observe errors, ignore success
~tap(file.read -> *)
| error e |> log.error(e.msg)
// No need to handle 'success' branch!
```

This makes taps perfect for focused observation:
```koru
// Security audit: only track access grants
~tap(auth.check -> grant.access)
| user u |> audit.log("Access granted:", u.id)
// Don't care about denials
```

---

## Multiple Taps

Multiple taps can observe the same transition:

```koru
// Tap 1: Logging
~tap(auth.check -> *)
| success u |> log.info("Login:", u.username)

// Tap 2: Metrics
~tap(auth.check -> *)
| success u |> metrics.increment("logins")

// Tap 3: Analytics
~tap(auth.check -> *)
| success u |> analytics.track(u.id)
```

**Independence**: Each tap executes independently. Order doesn't affect correctness.

See: [604_multiple_taps](../604_multiple_taps/)

---

## When Clauses in Taps

Taps support conditional observation with `when` clauses:

```koru
~tap(http.request -> *)
| response r when r.status >= 500 |> alert.send("Server error")
| response r when r.status >= 400 |> log.warn("Client error")
// No catch-all required in taps!
```

Unlike regular flows, taps don't require a catch-all when using `when` clauses.

See: [609_when_clauses](../609_when_clauses/)

---

## Module-Qualified Taps

Taps can observe imported events:

```koru
~import "$std/io"

// Observe io.print calls
~tap(* -> io.print)
| transition t |> metrics.increment("prints")
```

See: [606_module_taps](../606_module_taps/)

---

## Tap Chains

Taps can observe chains of events:

```koru
// Observe specific flow path
~tap(auth.check -> grant.access)
| user u |> log.info("Access granted:", u.id)

~tap(grant.access -> database.query)
| query q |> log.debug("DB query:", q.sql)
```

**Use case**: Track execution paths through the system.

See: [607_tap_chains](../607_tap_chains/)

---

## Taps with Labels

Taps can observe labeled loops and jumps:

```koru
~#retry http.get(url: endpoint)
| ok o |> success { data: o.body }
| error e |> @retry(url: endpoint)

// Observe retry attempts
~tap(http.get -> #retry)
| error e |> metrics.increment("retries")
```

See: [608_taps_with_labels](../608_taps_with_labels/)

---

## Implementation

### Zero-Cost Inlining

Taps compile to inline code at each transition point:

```koru
// Source
~tap(file.read -> *)
| error e |> log.error(e.msg)
```

```zig
// Generated (conceptual)
const result = file.read.handler(.{ .path = path });

// Tap injected here
if (result == .error) {
    log.error.handler(.{ .msg = result.error.msg });
}

// Continue main flow
switch (result) {
    .success => { /* ... */ },
    .error => { /* ... */ },
}
```

### Tap Registry

Taps are collected during parsing and injected at code generation:
1. Parser identifies all `~tap(source -> dest)` patterns
2. Creates tap registry mapping (source, dest) → [taps]
3. Code generator injects tap calls at matching transitions

---

## Design Rationale

**Why taps instead of middleware?**
- Zero runtime overhead (inlined, not dynamic)
- Statically analyzable (know all observation points)
- Type-safe (branch payloads are typed)
- Composable (multiple independent taps)

**Why read-only?**
- Prevents hidden side effects
- Makes correctness easier to reason about
- Enables parallel tap execution
- Compiler can optimize more aggressively

**Why non-exhaustive?**
- Focused observation (only care about errors, not success)
- Less boilerplate
- Easier to add/remove taps without breaking flow

---

## Verified By Tests

- [601_shorthand_syntax](../601_shorthand_syntax/) - Basic tap syntax
- [602_annotation_syntax](../602_annotation_syntax/) - Conditional taps
- [603_event_taps](../603_event_taps/) - Basic event observation
- [603b_event_taps_nested](../603b_event_taps_nested/) - Nested tap patterns
- [604_multiple_taps](../604_multiple_taps/) - Multiple independent taps
- [605_wildcard_patterns](../605_wildcard_patterns/) - `*` wildcards
- [606_module_taps](../606_module_taps/) - Observing imported events
- [607_tap_chains](../607_tap_chains/) - Multi-event observation
- [608_taps_with_labels](../608_taps_with_labels/) - Taps on labeled loops
- [608_transition_metatype](../608_transition_metatype/) - Transition metadata
- [609_when_clauses](../609_when_clauses/) - Conditional observation

---

## Related Specifications

- [Core Language - Events](../000_CORE_LANGUAGE/SPEC.md#event-declaration) - What can be observed
- [Control Flow - Continuations](../100_CONTROL_FLOW/SPEC.md#continuations) - Branch syntax
- [Control Flow - When Clauses](../100_CONTROL_FLOW/SPEC.md#when-clauses) - Conditional logic
- [Imports](../300_IMPORTS/SPEC.md) - Module-qualified observation
