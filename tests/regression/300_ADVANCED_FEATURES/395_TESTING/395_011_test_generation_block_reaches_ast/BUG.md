# Aspirational: test-generation's output is discarded before it reaches the AST

Red on purpose. It flips green when `koru_std/compiler.kz:1361-1371` is fixed,
and at that moment it also becomes the corpus witness for `__mock_result_{}`,
which the variant-coverage wall reports UNCOVERED today.

## The defect

`test-generation` (compiler.kz:1309) collects the flows it lowered into
`test_flows_to_remove`, then rebuilds the item list deciding replacement by
pointer identity:

```zig
for (mutable_ctx.ast.items) |item| {          // 1361 — by-value capture
    if (item == .flow) {
        const flow = &item.flow;              // 1363 — address of the copy
        for (test_flows_to_remove.items) |test_flow| {
            if (test_flow == flow) {          // 1367
```

`test_flows_to_remove` was filled from a *different* by-value `for` at 1322,
so the two `&item.flow` addresses are addresses of two separate per-loop
temporaries. `should_replace` is never true: the `~test` flow survives
untouched and the generated `test "..." { ... }` inline_code is dropped.

Consequences: every block this pass produces is thrown away, and
`__mock_result_{}` — real emitted Zig, written bare through
`code_emitter.write` at compiler.kz:1727-1732 — can appear in no artifact.

## Evidence (2026-08-06, this test's own program shape)

The arm provably executes:

- A mock naming a branch the event does not declare panics at
  compiler.kz:1504; the stack trace reads
  `processTestFlow` ← `test_generation_event.handler` ← `coordinate_event.handler`.
- The same program with an impure `withdraw` and **no** mock panics at
  compiler.kz:1542, `Test '...' has impure events without mocks`. That proves
  both that the `~test` body parsed into a flow and that the mock map hits for
  the mocked variant — the same map and key `emitFlowWithMocks` tests at
  compiler.kz:1722.

The product provably does not land:

- `std/compiler:ast-dump` inserted immediately after
  `std/compiler:test-generation.default(ctx)` shows the `~test` invocation
  still present as a `flow` item and no `inline_code` item anywhere in the AST.

## Neighbouring findings, not fixed here

- `koru_std/testing.kz:685` defines a second `emitFlowWithMocks` with no caller
  anywhere in the repo.
- The `~test` body is parsed under the synthetic filename `__test__.kz`
  (testing.kz:280, compiler.kz:1460), so a body written without `~` prefixes
  parses as Zig host lines — zero mocks, zero flows. This test's body is
  `~`-prefixed, matching 395_008.
