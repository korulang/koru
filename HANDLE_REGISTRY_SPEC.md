# Handle Registry Spec: Handle IDs and Discharge

**Status:** Draft for team review
**Author:** Claude (Thor), with Lars (Cap)
**Date:** 2026-01-24

## Problem Statement

The interpreter needs to:
1. Track resources created during execution (connections, files, images, etc.)
2. Actually invoke discharge events at cleanup time (not just mark handles)
3. Support the bridge vision: AI inspection of active resources across sessions

Current state:
- `Handle` stores binding name, obligation, discharge_event, discharged flag
- Auto-discharge only marks handles as discharged, does not invoke cleanup
- Binding names (`result.db`) do not align with discharge lookup (arg values)
- No stable, serializable handle ID passed through flows

## Design: Handle IDs (No Pointers)

Use **handle IDs as strings** in the value system. The interpreter never touches pointers.
Event handlers are responsible for creating/looking up the actual resource and returning
(or accepting) a handle ID string.

This keeps the runtime portable and AI-friendly:
- Handle IDs are serializable and safe for untrusted code
- Bridge inspection is just a list of IDs + metadata
- No pointer encoding/decoding

A host-side registry (or module-local map) can map `handle_id -> resource`.
The interpreter only stores handle IDs and obligation metadata.

## Constraints

Koru allows **one phantom obligation per type**. Multiple obligations are allowed
only if they come from **multiple fields** (each field has at most one obligation).

Handles are **scope-local**:
- A handle ID is only valid within the scope/registry instance that created it.
- `fs:read_lines` in scope A does not interop with `fs:read_lines` in scope B.
- Cross-scope discharge is invalid unless both events are in the same scope.

This avoids accidental capability leaks and keeps scopes as the unit of isolation.

Enforcement options (choose one):
- Store `scope_name` (or a stable scope hash) on each `Handle` and check on acquire/discharge.
- Prefix handle IDs with a scope tag (e.g., `api:h123`) and reject mismatches.

## Module-Namespaced Obligations

Phantom obligations are **fully qualified** by their originating module:

- `sqlite3:opened` - a SQLite connection
- `fs:opened` - a file handle
- `mem:allocated` - a memory buffer
- `reaper:opened` - a REAPER audio track

This prevents collision (`fs:opened` vs `sqlite3:opened`) and enables cross-module reasoning.
A higher-level module can work with obligations from multiple domains:

```koru
// Orchestration that understands both sqlite3 and mem obligations
~do_buffered_query(conn: *Connection[sqlite3:opened!], buf: *Buffer[mem:allocated!])
| result { ... }
```

The registry captures the full `module:name` pair for each obligation.

## Data Structures

```zig
pub const Handle = struct {
    /// Unique ID within this pool (persistent, incrementing)
    id: u32,

    /// Stable handle ID (string) passed through flows
    handle_id: []const u8,

    /// Module that defines this obligation (e.g., "sqlite3", "fs", "mem")
    obligation_module: []const u8,

    /// Obligation name within that module (e.g., "opened", "allocated")
    obligation_name: []const u8,

    /// Event that discharges this obligation (e.g., "sqlite3:close")
    discharge_event: []const u8,

    /// Whether this handle has been discharged
    discharged: bool,

    /// Which event created this resource (e.g., "sqlite3:open")
    created_by_event: []const u8,

    /// Optional resource type name for inspection (e.g., "Connection")
    resource_type: []const u8,

    /// Helper to get fully-qualified obligation string
    pub fn fqObligation(self: *const Handle, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "{s}:{s}", .{self.obligation_module, self.obligation_name})
            catch self.obligation_name;
    }
};

pub const HandlePool = struct {
    handles: std.ArrayList(Handle),
    next_id: u32,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) HandlePool;
    pub fn deinit(self: *HandlePool) void;

    /// Register a new handle and return its pool ID
    pub fn acquire(
        self: *HandlePool,
        handle_id: []const u8,
        obligation_module: []const u8,
        obligation_name: []const u8,
        discharge_event: []const u8,
        created_by_event: []const u8,
        resource_type: []const u8,
    ) !u32;

    /// Mark a handle as discharged by pool ID
    pub fn dischargeById(self: *HandlePool, id: u32) void;

    /// Find handle by handle_id (for explicit discharge)
    pub fn findByHandleId(self: *HandlePool, handle_id: []const u8) ?*Handle;

    /// Get all undischarged handles (for cleanup / inspection)
    pub fn getUndischarged(self: *const HandlePool) []const Handle;

    /// Get ALL handles (for bridge inspection - includes discharged)
    pub fn getAllHandles(self: *const HandlePool) []const Handle;

    /// Count undischarged
    pub fn countUndischarged(self: *const HandlePool) usize;
};
```

## Registry Metadata Needed

To wire handle IDs correctly, scope registration must capture **field/arg names**:

- **Creates:** for each obligation, which output field holds the handle ID
- **Discharges:** for each obligation, which input arg carries the handle ID

Example metadata shape:

```zig
pub const CreateSpec = struct {
    obligation_module: []const u8,  // "sqlite3"
    obligation_name: []const u8,    // "opened"
    field_name: []const u8,         // "conn" (which output field holds handle ID)
    resource_type: []const u8,      // "Connection"
};

pub const DischargeSpec = struct {
    obligation_module: []const u8,  // "sqlite3"
    obligation_name: []const u8,    // "opened"
    arg_name: []const u8,           // "conn" (which input arg carries handle ID)
};
```

This avoids guessing by position, enables cross-module reasoning, and works with
multiple obligations per event (as long as each obligation maps to a unique field/arg name).

## Auto-Discharge Flow

At request end (success, error, or exhaustion), for local pools:

```zig
const undischarged = active_pool.getUndischarged();
for (undischarged) |handle| {
    const discharge_inv = buildDischargeInvocation(
        handle.discharge_event,
        handle.handle_id,
        discharge_arg_name_for(handle.obligation),
        ctx.allocator,
    );

    var discharge_result: DispatchResult = undefined;
    if (ctx.dispatcher) |dispatcher| {
        dispatcher(&discharge_inv, &discharge_result) catch |err| {
            std.debug.print("[AUTO-DISCHARGE] Failed {s}: {s}\n",
                .{handle.discharge_event, @errorName(err)});
        };
    }

    active_pool.dischargeById(handle.id);
}
```

## Handle Creation (in executeFlow)

When an event creates obligations:

```zig
if (ctx.creates_obligations_fn) |creates_fn| {
    const creates = creates_fn(event_name); // []CreateSpec
    for (creates) |spec| {
        const discharge_event = discharge_event_for(spec.obligation_module, spec.obligation_name);
        const handle_id = getFieldValue(dispatch_result.fields, spec.field_name);
        _ = pool.acquire(
            handle_id,
            spec.obligation_module,
            spec.obligation_name,
            discharge_event,
            event_name,
            spec.resource_type,
        ) catch {};
    }
}
```

## Explicit Discharge (user calls close)

When a discharge event is called explicitly:

```zig
if (ctx.discharges_obligations_fn) |discharges_fn| {
    const discharges = discharges_fn(event_name); // []DischargeSpec
    for (discharges) |spec| {
        const handle_id = getArgValue(evaluated_inv.args, spec.arg_name);
        if (pool.findByHandleId(handle_id)) |handle| {
            pool.dischargeById(handle.id);
        }
    }
}
```

## Bridge Integration

The bridge holds a `HandlePool` that persists across requests.
Inspection returns handle IDs and metadata (not pointers).

Example view:

```
Bridge session: "audio-project-123"
Active handles:
  #1: conn_001 [sqlite3:opened]
      type: Connection
      created by: sqlite3:open
      discharge: sqlite3:close

  #2: img_004 [img:loaded]
      type: Image
      created by: img:load
      discharge: img:close

  #3: track_019 [reaper:opened]
      type: AudioTrack
      created by: reaper:open_track
      discharge: reaper:close_track

  #4: buf_012 [mem:allocated]
      type: Buffer
      created by: mem:alloc
      discharge: mem:free
```

AI can reason across domains: "I have an open database connection and an allocated buffer."

## Files to Modify

1. **`koru_std/interpreter.kz`**
   - Update `Handle` struct and `HandlePool`
   - Update `acquire` signature and callers
   - Implement actual discharge invocation in auto-discharge
   - Update handle creation in `executeFlow`

2. **`koru_std/runtime.kz`**
   - Extend registry generation to capture create/discharge field/arg names

3. **`koru-libs/bridge/index.kz`** (future)
   - Add `inspectHandles` method
   - Expose handle metadata for AI inspection

## Testing Strategy

1. **Basic discharge invocation**
   - Create resource, auto-discharge runs, verify cleanup event called

2. **Explicit discharge**
   - Create resource, explicitly close it, verify handle marked discharged

3. **Error path discharge**
   - Create resource, trigger error, verify cleanup still happens

4. **Budget exhaustion discharge**
   - Create resource, exhaust budget, verify cleanup happens

5. **Bridge persistence**
   - Create resource with bridge pool, end request, verify handle persists
   - Start new request with same bridge, verify handle still visible

## Open Questions

1. **Handle ID format:** who generates IDs and what constraints apply?
2. **Resource type metadata:** should events provide it, or should it be optional?

## Future Optimization: Obligation Tags

Since scope registration knows all possible obligations at comptime, we can optimize
string storage to integer tags:

```zig
// Generated per-scope at registration
const obligation_modules = [_][]const u8{ "sqlite3", "mem" };
const obligation_names = [_][]const u8{ "opened", "prepared", "allocated" };

// Handle stores tags instead of strings
pub const Handle = struct {
    obligation_module_tag: u8,  // Index into obligation_modules
    obligation_name_tag: u8,    // Index into obligation_names
    // ...
};
```

Benefits:
- No string comparisons in hot paths
- Smaller memory footprint
- Type safety at scope boundary
- Lookup functions provide human-readable names for inspection

This is a pure optimization - the string-based design is correct and can be
upgraded later without changing the external interface.

## Implementation Order

## Implementation Plan (Full)

**Ownership:** Claude first pass, Codex review/cleanup.

### Phase 0: Decisions
1. **Scope enforcement choice**: recommend storing `scope_name` on each `Handle`
   (avoids changing handle ID format). If rejected, use scope-tagged handle IDs.

### Phase 1: Runtime Registry Metadata
2. Extend `~std.runtime:register` generation to emit:
   - `CreateSpec { obligation_module, obligation_name, field_name, resource_type }`
   - `DischargeSpec { obligation_module, obligation_name, arg_name }`
3. Emit per-scope lookup fns:
   - `get_creates_spec_<scope>(event_name) []const CreateSpec`
   - `get_discharges_spec_<scope>(event_name) []const DischargeSpec`
4. Wire these into `get_scope` table alongside cost/obligation lookups.

### Phase 2: HandlePool + Interpreter Wiring
5. Update `Handle` struct and `HandlePool.acquire` signature to include:
   - `handle_id`, `obligation_module`, `obligation_name`, `resource_type`
   - optional `scope_name` if Phase 0 chooses stored scope enforcement
6. Update `executeFlow`:
   - On create: read `CreateSpec` for the event, extract `handle_id`
     from `DispatchResult` by `field_name`, and `acquire`.
   - On explicit discharge: read `DischargeSpec`, extract `handle_id`
     from args by `arg_name`, and `dischargeById`.

### Phase 3: Auto-Discharge Invocation
7. Implement `buildDischargeInvocation` helper (arg-name aware).
8. On local pool cleanup (success/error/exhaustion):
   - Invoke discharge event per undischarged handle.
   - Mark discharged after invocation (or on success only; decide and document).

### Phase 4: Tests
9. Add regressions:
   - Basic auto-discharge (cleanup event called).
   - Explicit discharge path (handle marked discharged).
   - Error path cleanup.
   - Budget exhaustion cleanup.
   - Bridge persistence (handles survive, inspectable).

### Phase 5: Bridge
10. Add `inspectHandles` on `@koru/bridge` (future).


---

**Ready for review.**
