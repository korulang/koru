# 019 — bareiss vs dixon, same exact system

Measured 2026-11-26 on `rational-kit` at `ac997e7ea` (WSL Ubuntu 20.04,
x86_64, glibc-2.31 shim, ReleaseFast). Rig: `gen.py` emits `input.k`
(rounds nested inside each other's `| exact` arms — arm bodies are the
only way state crosses a union), `run.sh` builds once and re-runs.

## Design

A_k = A0^(2^k) over 5×5 rat cells, b = A_k·1 → **x = ones, known-exact**.
det(A_k) = det(A0)^(2^k) with det(A0) ≈ 10⁹, so intermediate-minor width
doubles per round: k=0 ≈ 10 digits, k=8 ≈ 2300 digits.

- **bareiss** (`solve`) — denom-clear to ℤ, fraction-free elimination,
  Rat back-substitution. Cost tracks minor width.
- **dixon** (`solve-dixon`, p=999983) — A⁻¹ over 𝔽_p, Hensel lift one
  digit/step, Wang recon under isqrt(p^k/2), full-ℚ `Z·x=C` witness.
  recon hits at step ~2 (x=1/1); but the residual check still multiplies
  through the big entries — Dixon is *flatter*, not flat.

## Time (ms) — 3 runs

| k | bareiss | dixon |
|---|--------:|------:|
| 0 | 0.059 / 0.036 / 0.034 | 0.172 / 0.197 / 0.127 |
| 2 | 0.073 / 0.071 / 0.034 | 0.185 / 0.177 / 0.131 |
| 4 | 0.108 / 0.087 / 0.088 | 0.219 / 0.179 / 0.182 |
| 5 | 0.178 / 0.138 / 0.138 | 0.269 / 0.274 / 0.195 |
| 6 | 0.344 / 0.360 / 0.240 | 0.438 / 0.300 / 0.300 |
| 7 | 0.552 / 0.792 / 0.702 | 0.673 / 0.623 / 0.865 |
| 8 | 2.411 / 2.247 / 2.249 | 2.316 / 1.550 / 1.469 |

## Reading it

- **Crossover ≈ k=7** (minors ~10¹⁷⁰⁰ wide): bareiss paid ~2×/round past
  k=5; dixon grew ~1.3×/round. Dixon's win is real but modest at 5×5 —
  its cost is residual+recon on full-width entries, not free.
- **Dixon's floor is ~0.1ms** — mod-p inverse + lift machinery is fixed
  overhead that loses badly below minors of a few hundred digits.
- Bareiss wins exactly where the design note predicted: small/moderate
  coefficient width, dimension-bound work. Dixon earns its slot at
  width — the crossover moves earlier as dimension grows (bareiss cost
  scales n³×width, dixon's mod-p elim pays width once, at read-in).
- **K=10 segfaults the compiler backend** — the nested-arm program at
  ~40 arm-depth dies with signal 11 during emission (a.out never built).
  K=9 is the measured wall; the crash is a compiler defect on deep
  arm nesting, not a runtime fault. Repro: `gen.py` with K=10.

## Custody findings baked into input.k

- `dup` record fields are individually consumable; **every field must be
  discharged on every union arm** — the phantom checker tracks
  obligations per arm path, so each `| dims`/`| singular`/`| open` arm
  frees the copies still live there.
- `lit { s }` takes `string<*>` (widened in this branch): canon text from
  `render` (`string<allocated!>`) feeds straight back in.
