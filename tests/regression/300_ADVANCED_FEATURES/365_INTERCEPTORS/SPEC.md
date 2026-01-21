# Interceptors Specification

> Payload transformation for event transitions with known destinations.

**Last Updated**: 2026-01-21
**Test Range**: 365_001-365_019
**Status**: DESIGN PHASE

---

## What Are Interceptors?

Interceptors transform payloads in-flight to a known destination event. Unlike taps (read-only observers), interceptors can **modify** the payload before it reaches the destination.

**Key Properties**:
- Transform payloads - can modify data before delivery
- **Single interceptor per destination** - compiler error if multiple declared
- Destination must be known (RHS cannot be wildcard for shape safety)
- Source can be wildcard (we don't care where it came from)
- Compile to zero-cost inlined code at transition points

---

## Comparison: Taps vs Interceptors

| Property | Taps | Interceptors |
|----------|------|--------------|
| Syntax | `~tap(source -> *)` | `~intercept(* -> dest)` |
| Known shape | LHS (source output) | RHS (dest input) |
| Can modify | NO - observe only | YES - transform payload |
| Multiple allowed | YES - independent | NO - compiler error |
| Wildcard position | RHS (destination) | LHS (source) |
| Use case | Logging, metrics, debugging | Enrichment, validation, transformation |

**The Symmetry**:
- **Tap**: "I know what's LEAVING, I'll watch it go anywhere"
- **Intercept**: "I know what's ARRIVING, I'll modify it before delivery"

---

## Basic Syntax

```koru
~intercept(* -> destination_event)
| payload p |> payload { field: transform(p.field) }
```

**Example**:
```koru
~import "$std/interceptors"

// Add timestamp to all log writes
~intercept(* -> log.write)
| payload p |> payload {
    logline: p.logline ++ " [" ++ timestamp() ++ "]",
    level: p.level
}
```

---

## The `payload` Binding

Unlike taps which receive branch outputs, interceptors receive the **destination's input payload**:

```koru
~event log.write { logline: []const u8, level: LogLevel }
| written {}

// Interceptor receives { logline, level } - the INPUT to log.write
~intercept(* -> log.write)
| payload p |> payload { logline: uppercase(p.logline), level: p.level }
```

The interceptor MUST return a `payload` that matches the destination's input shape.

---

## Single Interceptor Rule

Only ONE interceptor can be installed per destination. Multiple interceptors cause a **compile-time error**:

```koru
// In module_a.kz
~intercept(* -> log.write)
| payload p |> payload { logline: p.logline ++ " [A]", level: p.level }

// In module_b.kz
~intercept(* -> log.write)  // COMPILE ERROR: interceptor already installed
| payload p |> payload { logline: p.logline ++ " [B]", level: p.level }
```

**Error**: `error[KORU0XX]: duplicate interceptor for 'log.write' - already defined in module_a`

**Rationale**:
- No ordering ambiguity (which transform runs first?)
- No shape conflicts (each transform might expect different intermediate shapes)
- Explicit is better than implicit

---

## Use Cases

### Logging Enrichment
```koru
~intercept(* -> log.write)
| payload p |> payload {
    logline: p.logline,
    level: p.level,
    timestamp: now(),
    request_id: context.request_id()
}
```

### Input Validation
```koru
~intercept(* -> database.query)
| payload p |> {
    validate_sql(p.sql)  // Throws on SQL injection
    payload { sql: p.sql, timeout: p.timeout }
}
```

### Request Transformation
```koru
~intercept(* -> api.request)
| payload p |> payload {
    url: p.url,
    headers: p.headers ++ auth_headers(),
    body: p.body
}
```

### Metrics Injection
```koru
~intercept(* -> http.send)
| payload p |> {
    metrics.start_timer("http_request")
    payload { request: p.request }
}
```

---

## Protection: `[opaque]` Annotation

Events can opt-out of interception (and tapping) with `[opaque]`:

```koru
~[opaque] event auth.verify { token: []const u8 }
| valid { user: User }
| invalid { reason: []const u8 }
```

Attempting to intercept an opaque event causes a **compile-time error**:

```koru
~intercept(* -> auth.verify)  // COMPILE ERROR: cannot intercept opaque event
| payload p |> ...
```

**Use cases for `[opaque]`**:
- Security-sensitive events (auth, crypto)
- Performance-critical hot paths
- Events where transformation would break invariants

---

## Interceptors with Known Source

When the source IS known, you get both shapes:

```koru
~intercept(file.read -> cache.store)
| payload p |> payload {
    key: p.path,           // From file.read's transition
    value: p.contents,
    ttl: 3600
}
```

This is more restrictive but gives you access to source context.

---

## Implementation Notes

### Compile-Time Verification

The compiler verifies:
1. Interceptor output shape matches destination input shape
2. Only one interceptor per destination across all modules
3. `[opaque]` events are not intercepted

### Code Generation

```koru
// Source
~intercept(* -> log.write)
| payload p |> payload { logline: p.logline ++ " [intercepted]", level: p.level }
```

```zig
// Generated (conceptual)
fn log_write_with_intercept(original: LogWritePayload) void {
    // Interceptor transformation
    const modified = LogWritePayload{
        .logline = concat(original.logline, " [intercepted]"),
        .level = original.level,
    };

    // Call actual handler with modified payload
    log_write.handler(modified);
}
```

---

## Verified By Tests

- [365_001_basic_intercept](./365_001_basic_intercept/) - Basic interceptor syntax
- [365_002_payload_transform](./365_002_payload_transform/) - Payload modification
- [365_003_single_interceptor_error](./365_003_single_interceptor_error/) - Duplicate interceptor compile error
- [365_004_opaque_protection](./365_004_opaque_protection/) - `[opaque]` prevents interception
- [365_005_wildcard_source](./365_005_wildcard_source/) - `* -> dest` pattern
- [365_006_known_source](./365_006_known_source/) - `source -> dest` pattern
- [365_007_with_taps](./365_007_with_taps/) - Interceptors and taps together
- [365_008_cross_module](./365_008_cross_module/) - Interceptor in imported module

---

## Related Specifications

- [Taps & Observers](../360_TAPS_OBSERVERS/SPEC.md) - Read-only observation
- [Core Language - Events](../000_CORE_LANGUAGE/SPEC.md#event-declaration) - Event declaration
- [Annotations](../ANNOTATIONS.md) - `[opaque]` and other annotations
