# Signal routing is registry-driven — koru's signals name their sinks (belief)

Every signal family koru raises onto the Cordial bus carries a committed
declaration in `signals/<family>.signal`, and since 2026-07-05 that
declaration's `route:` line — never the producer, never host code — names
where firings go:

- `route: surface, wake` — the judgment vocabulary (contradiction,
  correction, regime-change, test-health, commit-silence, ...): renders on
  the OBS surface AND reaches Victoria's ambient ears.
- `route: surface, wmfx=regression_shape` — raw test-run telemetry
  (regression_wall_seconds, regression_cpu_seconds, regression_tests,
  regression_single_test_seconds): renders as a heartbeat card, is spooled
  to the WMFX model's live tick, and NEVER wakes a model directly. Only the
  engine's own flinch families escalate.

This is the "dumb signals, smart engine" doctrine made mechanical for the
test suite: a full-suite run or a standalone single-test run is routine
rhythm, visible but silent; surprise is computed by the engine, not assumed
by the producer. The bus router (6digit-cordial/src/bun/router.ts) enforces
the declarations; undeclared families quarantine surface-only as orphans.
The regression_shape model itself is the open next rung — until it lands,
telemetry accumulates durably in the wmfx spool.
