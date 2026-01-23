# Budgeted Interpreter Specification

> Metered execution with resource tracking and automatic cleanup.

## Overview

The budgeted interpreter extends Koru's runtime interpreter with:
1. **Budget tracking** - Events have costs, execution has limits
2. **Handle pool** - Resource handles tracked with obligations
3. **Auto-discharge** - Undischarged resources cleaned up at request end
4. **Bridges** - Persistent sessions across CLI invocations

## Budget System

### Event Costs

Events are registered with costs in the scope:

```koru
~std.runtime:register(scope: "api", auto_discharge: true) {
    fs:open(10)      // costs 10 tokens
    fs:read(5)       // costs 5 tokens
    fs:close(1)      // costs 1 token
    db:query(50)     // costs 50 tokens
}
```

### Execution with Budget

```koru
~std.interpreter:run(source: code, scope: "api", budget: 100)
| result r   |> // completed: r.value, r.used
| exhausted e |> // ran out: e.used, e.last_event
```

### Budget Response

Every response includes budget info:
```json
{
  "result": {"branch": "ok", "fields": {...}},
  "budget": {"used": 45, "remaining": 55}
}
```

## Handle Pool & Obligations

### Automatic Tracking

When an event returns a value with `[state!]` phantom type:
- Handle added to pool with obligation marker
- Symbolic name assigned (h1, h2, ...)

When an event with `[!state]` parameter is called:
- Matching handle marked as discharged
- Removed from active obligations

### Auto-Discharge

With `auto_discharge: true`:
- At request end, walk undischarged handles
- Call default discharge event for each
- Report what was cleaned up

```json
{
  "result": {...},
  "auto_discharged": ["h1", "h3"],
  "budget": {"used": 47}
}
```

### Discharge Mapping

Built at compile time from phantom types:
- `[state!]` on return → creates obligation
- `[!state]` on param → can discharge
- Single discharger → automatic default
- Multiple dischargers → use `[!]` annotated one

## Bridges

### Lifecycle

```bash
# Create bridge (new session)
$ koru
{"bridge": "8fedba", "handles": {}, "budget": {"remaining": 10000}}

# Execute with bridge
$ koru --bridge 8fedba '~fs:open(path: "x.txt") | ok f |> result { f.file }'
{"bridge": "8fedba", "result": {...}, "handles": {"h1": "File[opened]"}, "budget": {...}}

# Query state
$ koru --bridge 8fedba --handles
{"handles": {"h1": {"type": "File", "state": "opened", "meta": {...}}}}

# End session (auto-discharge all)
$ koru --bridge 8fedba --end
{"discharged": ["h1"], "final_budget": {"used": 12}}
```

### User Tiers & Refill

Bridges tied to user accounts with token bucket refill:

```bash
$ koru --user premium
{"bridge": "abc123", "budget": {"capacity": 50000, "refill_rate": 1000, "refill_interval": "1s"}}
```

## Test Matrix

| Test | Description |
|------|-------------|
| 410_001 | Basic budget tracking - event costs deducted |
| 410_002 | Budget exhaustion mid-flow |
| 410_003 | Handle pool - track opened resources |
| 410_004 | Auto-discharge on request end |
| 410_005 | Multiple handles, partial discharge |
| 410_006 | Scope with auto_discharge: false |
| 410_007 | Budget + handles combined |
| 410_008 | JSON output format |

## Design Decisions

1. **Costs are relative** - No fixed meaning, just ratios
2. **Budget is per-request** - Bridges manage across requests
3. **Auto-discharge is opt-in** - Scope declares cleanup semantics
4. **Handles are symbolic** - h1, h2 for token efficiency with LLMs
5. **Bridges are stateful** - Persist between CLI calls
