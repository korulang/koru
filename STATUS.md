# Interpreter Status

This document captures current interpreter/runtime behavior as implemented in this repo.
It is not aspirational.

## Runtime Entry Points
- `std.runtime:register` generates per-scope dispatchers, cost lookup, and obligation lookup tables.
- `std.runtime:get_scope` returns dispatcher + lookup fns by scope name.
- `std.runtime:run` is the one-shot path: parse + scope lookup + execute.
- `std.runtime:parse.source` and `std.runtime:eval` are the lower-level pieces.
- Runtime parsing is **fail-fast by default** (`fail_fast: true`), with an opt-out.

## Budgeting
- Budget is enforced in the interpreter via `BudgetState` + `cost_fn` (from scope).
- On budget exhaustion, execution returns `exhausted` and does **not** auto-discharge.

## Obligations and Handle Pool
- Obligations are extracted from event signatures via phantom types:
  - Output `[state!]` -> creates obligation.
  - Input `[!state]` -> discharges obligation.
- Handle pool entries store:
  - `binding` (string), `obligation` (string), `discharge_event` (string).
- Creation behavior:
  - Each created obligation is stored with a synthetic binding name:
    - `result.<branch>` or `result.<branch>.<i>` for multiple obligations.
- Discharge behavior:
  - If an event is marked as discharging, the pool discharges using **only the first arg's value**.
  - There is no mapping from env bindings to pool bindings yet.

## Auto-Discharge (Current)
- Local pools: after **successful** execution, undischarged handles are marked as discharged.
- External pools (bridge-managed): **no** auto-discharge.
- Error paths (dispatch error, parse error, budget exhaustion): **no** auto-discharge.

## Bridge Library
- `@koru/bridge` provides persistent `HandlePool` only.
- Budget/rate limiting are intentionally out of scope for the bridge.

## Known Gaps (Discharge Semantics)
- No immediate discharge for non-escaping resources.
- No actual discharge event invocation (only marking in local pool).
- Discharge lookup uses arg0 string, which does not align with synthetic pool bindings.
- Budget exhaustion does not trigger cleanup.

## Tests
- Runtime one-shot flow: scope lookup, budget exhaustion, event denied, scope not found.
- Fail-fast and lenient parsing behavior for runtime parsing.
