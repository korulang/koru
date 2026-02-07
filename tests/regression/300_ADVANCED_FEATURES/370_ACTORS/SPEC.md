# Koru Actors: Virtual Actor System

## Vision

Orleans-style virtual actors using only existing Koru primitives:
- `~[derive(actor)]` generates message events
- Tap pattern provides implementation
- Capture-like semantics for state mutation
- Abstract events for pluggable persistence
- MPSC rings for lock-free message transport
- Hierarchical ring topology for clustering

## Declaration

```koru
~[derive(actor)]event player { id: []const u8, gold: u16, health: u16 }
| add_gold { gold: u16 }
| take_damage { damage: u16 }
```

**Reading this:**
- Input fields = actor state schema (`id`, `gold`, `health`)
- Branches = messages the actor can receive (`add_gold`, `take_damage`)

## What Derive Generates

### 1. Message Events (one per branch)

```koru
~event player.add_gold { id: []const u8, gold: u16 }
| call { id: []const u8, gold: u16 }

~event player.take_damage { id: []const u8, damage: u16 }
| call { id: []const u8, damage: u16 }
```

Each message event has a single `| call |>` branch carrying the payload.

### 2. Actor Activation Event

```koru
~event player { id: []const u8 }
| as { id: []const u8, gold: u16, health: u16 }
```

Returns capture-like scope with hydrated state.

### 3. Persistence Interface (abstract events)

```koru
~abstract event player.load { id: []const u8 }
| loaded { id: []const u8, gold: u16, health: u16 }
| not_found {}

~abstract event player.store { id: []const u8, gold: u16, health: u16 }
| stored {}
```

User provides implementation via cross-module overrides (colon syntax).

## Implementation via Tap

```koru
~tap(player.add_gold)
| call c |> player(id: c.id)
    | as s |> player { gold: s.gold + c.gold }

~tap(player.take_damage)
| call c |> player(id: c.id)
    | as s |> player { health: s.health - c.damage }
```

**Flow:**
1. `| call c |>` - message arrives
2. `player(id: c.id)` - activate actor, load state
3. `| as s |>` - capture-like scope with current state
4. `player { ... }` - branch constructor returns new state (persisted)

## Persistence Implementation

### Test Mode (static data)
```koru
~player:load = loaded { id: id, gold: 100, health: 100 }
~player:store = stored {}
```

### SQLite
```koru
~player:load =
    sqlite.query(sql: "SELECT * FROM players WHERE id = ?", args: .{id})
    | row r |> loaded { id: r.id, gold: r.gold, health: r.health }
    | empty |> not_found {}

~player:store =
    sqlite.exec(sql: "INSERT OR REPLACE INTO players VALUES (?, ?, ?)",
                args: .{id, gold, health})
    | ok |> stored {}
```

## Memory Caching

State can be cached in-memory with lazy persistence:

```koru
// Flush dirty actors on program end
~tap(* -> koru:end)
| Transition |> actor.store:flush_dirty()
    | flushed |> _

// Or flush on timer pulse
~tap(timer:pulse)
| tick |> actor.store:flush_dirty()
    | flushed |> _
```

The `player { ... }` update marks state dirty; flush persists all dirty actors.

## Message Transport: MPSC Rings

### Single-Threaded Turns (Orleans Guarantee)
- Same actor ID messages execute sequentially
- Different actor IDs can execute in parallel

### Sharded MPSC Rings
```
Messages arrive (multiple producers)
            |
            v
    hash(actor_id) % N
            |
   +--------+--------+
   v        v        v
 [Ring0]  [Ring1]  [Ring2]   <- N MPSC rings
   |        |        |
   v        v        v
 [Pump0]  [Pump1]  [Pump2]   <- N single consumers
```

- `hash("alice") % 3 = 1` → Ring1
- `hash("bob") % 3 = 2` → Ring2
- Same actor always same ring = sequential execution
- Lock-free: MPSC rings, single-threaded consumers

### Pump Loop
```koru
~#pump player.ring:dequeue(shard: i)
| msg m |> player.add_gold(id: m.id, gold: m.gold)
    | call |> _  // Tap handles it
```

## Distributed: Hierarchical Rings

From beist-rings architecture:

```
Level 0: [Cluster Ring]     <- cross-machine (network)
              |
Level 1: [Node Ring]        <- per-machine
              |
Level 2: [Actor Type Ring]  <- per-type (player, inventory)
              |
Level 3: [Shard Rings]      <- MPSC per hash(actor_id) % N
```

Bloom-routed: actor ID hashes to bloom pattern, routes to correct node/shard.

## Orleans Feature Checklist

- [x] Virtual actors (always exist, activate on demand)
- [x] Single-threaded turns (MPSC sharding)
- [x] Memory caching (in-process state)
- [x] Lazy persistence (flush dirty)
- [x] Pluggable storage (abstract events)
- [x] Location transparency (bloom routing)
- [x] Clustering (hierarchical rings)

## Capture Reuse

The `| as s |>` scope uses capture semantics. Options:

### A. Refactor capture codegen for reuse
Extract capture's AST-to-Zig codegen from `control.kz` to shared module.
Actor derive generates CaptureNode, reuses existing emitter.

### B. Generate capture invocation
Actor derive generates `capture(state)` call inline:
```koru
// Generated tap handler internally does:
player.load(id: c.id)
| loaded state |> capture(state)
    | as s |> ...
    | captured final |> player.store(id: c.id, gold: final.gold, ...)
```

### Recommendation
**Option A** - refactor for reuse. Capture codegen is battle-tested.
The actor `| as s |>` IS capture, just with persistence bookends.

## Implementation Steps

1. **Refactor capture codegen** - extract to reusable module
2. **Create actors.kz** - the derive handler
3. **Generate message events** - one per branch with `| call |>`
4. **Generate activation event** - loads state, returns `| as s |>`
5. **Generate persistence interface** - abstract load/store events
6. **Wire tap pattern** - intercept messages, activate, update
7. **Integrate rings.kz** - MPSC transport layer
8. **Test with static persistence** - prove pattern works
9. **Add SQLite impl** - real persistence
10. **Add dirty tracking** - memory caching
11. **Add flush taps** - lazy persistence

## Example: Complete Usage

```koru
~import "$std/actors"
~import "$std/rings"
~import "$app/db"

// Declaration
~[derive(actor)]event player { id: []const u8, gold: u16, health: u16 }
| add_gold { gold: u16 }
| take_damage { damage: u16 }

// Persistence (user provides)
~player:load = app.db:player.get(id: id)
    | found p |> loaded { id: p.id, gold: p.gold, health: p.health }
    | missing |> not_found {}

~player:store = app.db:player.upsert(id: id, gold: gold, health: health)
    | ok |> stored {}

// Implementation (user provides)
~tap(player.add_gold)
| call c |> player(id: c.id)
    | as s |> player { gold: s.gold + c.gold }

~tap(player.take_damage)
| call c |> player(id: c.id)
    | as s |> player { health: s.health - c.damage }

// Transport (user wires)
~#pump player.ring:dequeue(shard: i)
| msg m |> player.add_gold(id: m.id, gold: m.gold)
    | call |> _

// Caching (optional)
~tap(* -> koru:end)
| Transition |> actor.store:flush_dirty() | flushed |> _
```

---

*"Virtual actors, zero new syntax, pure Koru composition."*
