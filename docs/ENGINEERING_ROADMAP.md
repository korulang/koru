# Engineering Health Report & Roadmap (Work Doc)

Date: 2026-02-03
Owner: Codex (with Claude as reviewer)

## Snapshot (Executive Summary)
- The compiler pipeline is coherent and modular, but DX and correctness drift apart due to inconsistent error propagation and a brittle AST JSON contract.
- Parser and structural validation are the highest leverage areas.
- Regression suite is strong but sensitive to schema changes; it needs explicit versioning or tolerant comparison.

## Strengths
- Real separation of concerns (parser / shape checker / emitter).
- Regression suite with crisp failure markers and rich coverage.
- Metacircular approach is bold and already productive.

## Key Issues (What’s Hurting Us)
### DX / Error Propagation
- Parse errors can be silently accepted (lenient parsing) unless explicitly surfaced.
- Some fatal errors return without reporter output (unknown label, unknown event, etc.).

### Correctness Gaps
- Label jump obligations are not enforced (documented regression).
- Module‑qualified loop labels fail resolution.

### Parser Stability
- Heuristics can over‑reject valid input (e.g., Zig code detection).
- Multi‑line parsing is brittle (brace/paren depth cases).

### AST JSON Contract
- AST JSON is compared as raw text; additive fields break tests.
- No schema versioning or tolerant diff.

### Memory / Lifecycle
- Known leaks and allocator ownership mismatches (shape checker). OK for CLI, risky for long‑running use.

## Priority Roadmap

### P0 — Trust & DX (Highest Impact)
1) **Strict compile mode:** if reporter has errors after parse, fail compilation unless explicitly in lenient / AST mode.
2) **Guarantee diagnostics:** any fatal error must emit a reporter error (no silent returns).

### P1 — Correctness
3) **Label jump obligation enforcement** (phantom resource obligations must be discharged before jumps).
4) **Module‑qualified loop resolution** (imported module events must resolve in loop labels).

### P2 — Parser Robustness
5) **Reduce heuristics** (tighten Zig‑code detection; prefer explicit syntax errors).
6) **Brace/paren depth handling** in multi‑line parsing (prevent silent truncation).

### P3 — Tooling / AST Stability
7) **AST JSON schema versioning** (`schema_version` in output).
8) **Tolerant JSON comparison** for parser tests (ignore additive keys).

## Work Plan (Proposed Sequence)
1) Implement strict compile mode + error propagation.
2) Fix label jump obligations + regression test.
3) Fix module‑qualified loop resolution + regression test.
4) Add AST JSON schema version + tolerant comparison.
5) Harden multi‑line parser handling.

## Testing Expectations
- Each change ships with a minimal regression test in `tests/regression/`.
- Parser changes should include a `PARSER_TEST` with `expected.json` updates.
- Record failures in `tests/broken/` only if not immediately fixable.

## Notes / Coordination
- Claude should review changes that alter error policy or AST JSON schema.
- Keep changes small and test‑driven (one failure → one fix).

