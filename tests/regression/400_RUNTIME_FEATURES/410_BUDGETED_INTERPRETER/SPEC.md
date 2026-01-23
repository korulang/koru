# Budgeted Interpreter Specification

> Metered execution with resource tracking and automatic cleanup.

## Overview

The budgeted interpreter extends Koru's runtime interpreter with:
1. **Budget tracking** - Events have costs, execution has limits
2. **Handle pool** - Resource handles tracked with obligations
3. **Auto-discharge** - Undischarged resources cleaned up at request end
4. **Bridges** - Persistent sessions (integration layer, not core)

## Budget System

### Event Costs

Events are registered with costs in the scope:

```koru
~std.runtime:register(scope: "api") {
    fs:open(10)      // costs 10
    fs:read(5)       // costs 5
    fs:close(1)      // costs 1
    db:query(50)     // costs 50
}
```

Obligations are NOT in the scope registration - they come from event signatures via phantom types.

### Execution with Budget

```koru
~std.interpreter:run(
    source: code,
    dispatcher: d,
    cost_fn: c,
    creates_obligation_fn: creates,
    discharges_obligation_fn: discharges,
    discharge_event_fn: discharge,
    budget: 100
)
| result r   |> // completed: r.value, r.used, r.handles
| exhausted e |> // ran out: e.used, e.last_event, e.handles
```

## Handle Pool & Obligations

### Phantom Type Syntax (in Event Signatures)

Obligations are specified in event signatures using phantom types:

```koru
// Creates obligation - [state!] suffix
~pub event open { path: []const u8 }
| ok { file: File[opened!] }    // Creates "opened" obligation

// Discharges obligation - [!state] prefix
~pub event close { file: File[!opened] }   // Discharges "opened"
| ok |>
```

### Scope Registration (Costs Only)

```koru
~std.runtime:register(scope: "api") {
    open(10)     // cost only - obligations from signature
    read(5)
    close(1)
}
```

### Generated Functions

For each scope, the compiler generates:
- `get_event_cost_<scope>(event) -> u64`

TODO: Extract obligations from event signatures:
- `get_creates_obligation_<scope>(event) -> ?[]const u8`
- `get_discharges_obligation_<scope>(event) -> ?[]const u8`
- `get_discharge_event_<scope>(obligation) -> ?[]const u8`

### Auto-Discharge

At request end, undischarged handles are logged. The interpreter reports:
- Handles still active
- Budget consumed

Full auto-discharge (calling discharge events) is the responsibility of the integration layer.

## Bridges: Integration Layer

**Bridges are NOT part of the interpreter core.** They are an integration pattern built on top of the primitives.

### Why Bridges Are External

The interpreter is stateless per invocation. Bridges provide:
- State persistence across invocations
- Symbolic handle naming (h1, h2, ...)
- Token bucket refill over time
- User tier management

These are deployment-specific concerns that belong in:
- **Orisha** - User sessions hold bridge state
- **Shell/REPL** - Process memory holds bridge state
- **CLI daemon** - Temp files or shared memory

### Bridge Library Pattern

A bridge library would wrap the interpreter:

```zig
const Bridge = struct {
    id: []const u8,
    handle_pool: HandlePool,
    budget_state: BudgetState,
    user_tier: UserTier,
    created_at: i64,
    last_activity: i64,

    pub fn execute(self: *Bridge, source: []const u8) !ExecuteResult {
        // Refill budget based on time elapsed
        self.refillBudget();

        // Run interpreter with our state
        var ctx = InterpreterContext{
            .budget = &self.budget_state,
            .handle_pool = &self.handle_pool,
            // ... other fields
        };

        return executeFlow(flow, &ctx);
    }

    pub fn end(self: *Bridge) !EndResult {
        // Auto-discharge all handles
        for (self.handle_pool.getUndischarged()) |h| {
            // Call discharge event
        }
        return .{ .discharged = ... };
    }
};
```

### Bridge CLI Pattern

A bridge CLI would manage bridge lifecycle:

```bash
# Create bridge (spawns daemon or writes state file)
$ koru-bridge new --user premium
{"bridge": "8fedba", "budget": {"capacity": 50000, "refill_rate": 1000}}

# Execute with bridge
$ koru-bridge exec 8fedba '~fs:open(path: "x.txt") | ok f |> result { f.file }'
{"result": {...}, "handles": {"h1": "opened"}, "budget": {"used": 10}}

# Query handles
$ koru-bridge handles 8fedba
{"h1": {"binding": "f.file", "obligation": "opened"}}

# End bridge
$ koru-bridge end 8fedba
{"discharged": ["h1"], "final_budget": {"used": 11}}
```

### Orisha Integration Pattern

```koru
// In request handler
~get_user_bridge(user_id: request.user)
| bridge b |>
    // Execute user code with their bridge
    ~interpret_with_bridge(bridge: b, source: request.code)
    | result r |> respond_200(body: r.value)
    | exhausted e |> respond_429(message: "Rate limit exceeded")
| no_bridge |>
    // Create new bridge for user
    ~create_bridge(user_id: request.user, tier: user.tier)
    | created b |> // ... recurse
```

## Test Matrix

| Test | Description |
|------|-------------|
| 410_001 | Basic budget tracking - event costs deducted |
| 410_002 | Budget exhaustion mid-flow |
| 410_003 | Handle pool - track opened resources |
| 410_004 | Auto-discharge on request end |
| 410_005 | Budget exhaustion with open handles |

## Design Decisions

1. **Costs are relative** - No fixed meaning, just ratios between operations
2. **Budget is per-request** - Interpreter is stateless, bridges manage across requests
3. **Obligations are explicit** - `->` creates, `<-` discharges in scope registration
4. **Bridges are integration** - Not interpreter core, built on top of primitives
5. **Symbolic handles** - Named h1, h2 for LLM token efficiency

## What's Implemented (Core)

- ✅ BudgetState with consume/remaining
- ✅ HandlePool with acquire/discharge/getUndischarged
- ✅ Event costs parsed from scope registration
- ✅ Cost lookup function generated (`get_event_cost_<scope>`)
- ✅ InterpreterContext extended with budget/pool fields
- ✅ Budget check before dispatch
- ✅ External handle_pool parameter for bridges

## What's TODO (Core)

- 🔲 Extract obligations from event signatures (phantom types)
- 🔲 Generate obligation lookup functions from signatures
- 🔲 Handle tracking after dispatch (needs obligation extraction)
- 🔲 Auto-discharge logging at request end (needs obligation extraction)

## Bridge Library (koru_std/bridge.kz)

The bridge library provides:
- ✅ `UserTier` enum (free/basic/premium/unlimited)
- ✅ `Bridge` struct with handle_pool, budget tracking, timestamps
- ✅ `BridgeManager` - dictionary of sessions by ID
- ✅ Token bucket refill based on elapsed time
- ✅ Capacity/refill rates per user tier

### Usage in Orisha/Shell

```zig
// Import bridge library
const bridge_lib = @import("bridge");
var manager = bridge_lib.BridgeManager.init(allocator);

// Handle request
var bridge = try manager.getOrCreate(session_id, .premium);
bridge.refillBudget();  // Token bucket refill

// Run interpreter with bridge's persistent pool
const result = interpreter.run(
    source, dispatcher, cost_fn, ...,
    bridge.availableBudget(),
    &bridge.handle_pool,  // Persistent!
);

// Update bridge state
bridge.consumeBudget(result.used);

// End session (caller calls discharge events)
if (manager.end(session_id)) |handles| {
    for (handles) |h| { /* call discharge event */ }
}
```

## What's External (Not in koru_std)

- 🔲 CLI bridge management tool (koru-bridge)
- 🔲 Orisha session integration
- 🔲 Shell/REPL integration
