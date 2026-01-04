# ECS vs Koru Taps: Reactive Entity Processing

## The Question

Can Koru's compile-time fused taps compete with ECS archetype iteration for reactive entity processing - **without the archetype management overhead**?

## The Hypothesis

Traditional ECS wins at batch processing because archetype tables pack entities with the same components contiguously in memory. But this comes with costs:

- **Archetype swaps**: Adding/removing components moves entities between tables
- **Change detection**: Tracking which components changed requires memory overhead
- **Event systems**: Reacting to changes often falls back to callback dispatch

Koru taps offer an alternative:

- **Static entity shapes**: Entities don't change composition at runtime
- **Compile-time fusion**: Taps are spliced directly into producer code
- **`when` as query**: Conditional taps compile to inline `if` statements

## The Model

```
Traditional ECS:
┌─────────────────────────────────────────┐
│ Archetype Table (entities with Health)  │
│ ┌───┬───┬───┬───┬───┬───┬───┬───┬───┐   │
│ │ 0 │ 3 │ 7 │12 │15 │22 │...│   │   │   │  ← Only entities with Health
│ └───┴───┴───┴───┴───┴───┴───┴───┴───┘   │
└─────────────────────────────────────────┘
         ↓ iterate (cache-friendly)
    system(health) { ... }


Koru Taps (striping):
┌─────────────────────────────────────────┐
│ Entity Storage (all entities, stable)   │
│ ┌───┬───┬───┬───┬───┬───┬───┬───┬───┐   │
│ │ 0 │ 1 │ 2 │ 3 │ 4 │ 5 │ 6 │ 7 │...│   │  ← All entities, never move
│ └───┴───┴───┴───┴───┴───┴───┴───┴───┘   │
└─────────────────────────────────────────┘
         ↓ stripe over all
    if (when_condition) { fused_tap_code(); }  ← inline check
```

## What We're Comparing

| Aspect | Bevy ECS | Koru Taps |
|--------|----------|-----------|
| Query mechanism | Archetype iteration | `when` conditionals |
| Memory layout | Packed by archetype | Stable array |
| Reactivity | Change detection / events | Compile-time fusion |
| Component add/remove | Archetype swap (expensive) | N/A (static shapes) |
| Observer pattern | Runtime dispatch | Zero (compiled away) |

## Benchmark Scenarios

### Scenario 1: Dense Iteration
- 100K entities, all have the target component
- Process every entity
- **Expected**: ECS wins (cache locality of packed table)

### Scenario 2: Sparse Filtering
- 100K entities, 10% have the target component
- Process only matching entities
- **Expected**: ECS wins (only iterates 10K), Koru checks all 100K

### Scenario 3: Multi-Observer Reactivity
- 100K entities, emit damage events
- 10 observers per event (health bar, achievements, audio, particles, etc.)
- **Expected**: Koru wins (zero dispatch overhead)

### Scenario 4: Conditional Observers (Achievement Pattern)
- 100K events, 100 achievement conditions
- Average 2-3 achievements trigger per event
- **Expected**: Koru wins big (conditions are inline `if`, no dispatch)

### Scenario 5: Component Churn
- 10K entities, rapidly adding/removing components
- Systems query for changing compositions
- **Expected**: Koru wins (no archetype swaps, static shapes)

## The Insight

Koru taps aren't trying to replace ECS batch processing. They're offering a different trade-off:

**ECS**: "Pack entities by shape, iterate packed tables"
**Taps**: "Keep entities stable, fuse reactive logic at compile time"

For games that are:
- Heavy on reactivity (damage → health bar → death → particles → sound)
- Light on component churn
- Willing to trade query filtering for observer fusion

...taps might be faster overall because the overhead they eliminate (dispatch, subscription management, archetype swaps) exceeds the overhead they accept (checking conditions on non-matching entities).

## Implementation Notes

### Bevy Baseline
```rust
// Scenario 3: Multi-observer
fn damage_system(query: Query<&mut Health>) { ... }
fn health_bar_system(query: Query<(&Health, &HealthBar), Changed<Health>>) { ... }
fn achievement_system(query: Query<&Health, Changed<Health>>) { ... }
// etc - each system has its own query and change detection
```

### Koru Implementation
```koru
~tap(damage -> *)
| applied a |> update_health_bar(entity: a.target, health: a.remaining)
| applied a |> check_achievements(entity: a.target)
| applied a |> play_sound(entity: a.target, sound: "hit")
| applied a |> spawn_particles(entity: a.target)
| lethal |> trigger_death(entity: a.target)
// All fused into damage proc at compile time
```

## Status

- [ ] Define entity data structure
- [ ] Implement Bevy baseline
- [ ] Implement Koru tap version
- [ ] Run scenarios 1-5
- [ ] Analyze results
- [ ] Write up findings

## The Meta-Point

This benchmark isn't about "Koru vs Bevy" - both are excellent. It's about understanding **when each model wins** and whether Koru's compile-time fusion offers a viable alternative for reactive-heavy workloads.

---

*"The more observers you need, the bigger Koru wins."*
