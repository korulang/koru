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

## Data Structures

```zig
pub const Handle = struct {
    /// Unique ID within this pool (persistent, incrementing)
    id: u32,

    /// Stable handle ID (string) passed through flows
    handle_id: []const u8,

    /// Phantom obligation type (e.g., "opened", "prepared")
    obligation: []const u8,

    /// Event that discharges this obligation (e.g., "close")
    discharge_event: []const u8,

    /// Whether this handle has been discharged
    discharged: bool,

    /// Which event created this resource (for inspection)
    created_by_event: []const u8,

    /// Optional resource type name for inspection (if provided by event)
    resource_type: []const u8,
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
        obligation: []const u8,
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
pub const CreateSpec = struct { obligation: []const u8, field_name: []const u8 };
pub const DischargeSpec = struct { obligation: []const u8, arg_name: []const u8 };
```

This avoids guessing by position and works with multiple obligations per event
(as long as each obligation maps to a unique field/arg name).

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
        const discharge_event = discharge_event_for(spec.obligation);
        const handle_id = getFieldValue(dispatch_result.fields, spec.field_name);
        _ = pool.acquire(
            handle_id,
            spec.obligation,
            discharge_event,
            event_name,
            resource_type_for(spec.obligation),
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
  #1: conn_001 [opened!]
      created by: sqlite3:open
      discharge: sqlite3:close

  #2: img_004 [loaded!]
      created by: img:load
      discharge: img:close

  #3: track_019 [opened!]
      created by: reaper:open_track
      discharge: reaper:close_track
```

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

## Implementation Order

1. Update `Handle` struct
2. Update `HandlePool.acquire` signature
3. Extend registry generation with create/discharge field+arg names
4. Update handle creation in `executeFlow`
5. Implement `buildDischargeInvocation` helper
6. Implement actual discharge invocation in auto-discharge
7. Update explicit discharge path
8. Write tests

---

**Ready for review.**
