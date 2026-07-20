# 690_050 — store shape is selected by CAPACITY (ruling residue)

Ruled with Lars 2026-07-21, on a design walk that started from "why is anything
called *singleton*?" and ended by nailing the model down to the original vision.

## The real distinction (not arbitrary): reactive VALUE vs reactive CONTAINER

Two genuinely different things live under `std/store`, with different ops and
different access surfaces (grounded in the op-split):

| | VALUE (Redux store) | CONTAINER (collection) |
|---|---|---|
| ops | `stored` + `watch` | `insert` / `query` / `preorder` / `take` / row-`stored` |
| access | `store.field` (direct) | `store[r].field` (indexed) |
| lifecycle | always present; reacts on FIELD CHANGE | grows from empty; reacts on inserted/removed/updated |

Two shapes existing is CORRECT. What was wrong was (a) the SELECTOR and (b) the
NAMES.

## The ruling (the surface — locked)

1. **CAPACITY selects the shape.** `capacity` defaults to **1** → the VALUE
   shape (the singular case is just the default). `capacity > 1` → the CONTAINER
   shape. Capacity describes how it is EMITTED; it is the only selector.
2. **Initialization is ORTHOGONAL.** A field default (seed) means only "this
   column has a default value" — legal at ANY capacity, NEVER the shape
   selector. (A cap-N container may default `hp: 100`; a cap-1 value may be
   uninitialized.) The old seeded-vs-bare coupling conflated initialization with
   cardinality — two orthogonal axes welded by a spelling coincidence.
3. **Access: indexed `store[i].field` is UNIVERSAL; `store.field` is cap-1
   SUGAR.** So bumping a store's capacity 1→N does NOT shatter every call site.

## The names

"Singleton" (software-pattern baggage) and "plural" describe only COUNT, hiding
the value-vs-container distinction. Prefer surfacing capacity; internal emission
strategies may keep any names.

## Implementation (deferred, performance-driven — the surface above does not
depend on this)

The store is a COMPTIME TRANSFORM: surface and emission are decoupled by
construction. Keep the TWO specialized emissions (they are the perf-optimal
strategy, and both already exist):
- **cap-1 → a plain struct/value** — stack-resident, direct access, no indexing/
  bounds/len. Optimal for the always-one value.
- **cap-N → SoA arrays** — cache-friendly; insert/iterate/take.
"Unify to one container vs keep two" is a LATER call, made with a profiler, not
now. Highest-performance-potential wins (Lars's standing call).

### The change is small at the pivot, with a migration tail
- The entire container branch vocabulary (insert/query/take/stripe + inserted/
  removed/updated) is ALREADY gated behind ONE fork: `if (is_plural)`
  (store.kz:526). A value store never emits those units — the guard is
  STRUCTURAL, not a runtime check. This is the load-bearing pivot.
- So the core edit is: redefine `is_plural := capacity > 1` (today it is
  `bare_count != 0`, store.kz:444), demote seeding to "optional per-column
  default" (dissolve the seeded+bare mixing wall :441; re-key value_type :499),
  and make `capacity` (:533) the universal selector defaulting to 1.
- **Migration tail (the real work):** ~31 bare-plural stores across the corpus +
  koru-libs packages rely on bare-without-capacity == plural. Under the new
  selector they must declare `capacity: N` (greenfield: migrate, no shim). Broad
  + mechanical + must keep the board 0-broken → a Fable-shaped job.

## Order
Land THIS ruling first. Then plural-mixed scalar columns (690_049) on the
settled model. Then strings/references — the tier where `take`/discharge
ownership finally has bytes to free.
