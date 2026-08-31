# Koru

Koru is an event continuation/effect language with backends for Zig and JavaScript.

```koru
import std/io

event greet { name: string } -> string

greet -> "Hello, " ++ name ++ "!"

greet ("World"): msg |> std/io:print.ln(msg)
```

## Building

Requires Zig 0.15.1 or later.

```bash
zig build
```

## Repository map

The root carries the compiler plus the ecosystem that keeps it honest. Every
directory is deliberate; the map is so the glance reads that way.

| Path | What it is |
|---|---|
| `src/` | The metacircular compiler pipeline (Zig). `koruc` parses Koru and emits the backend build. |
| `koru_std/` | The standard library (Koru), including the compiler's own semantic passes and the self-hosted `compiler.kz`. |
| `tests/` | The regression suite — the language's ground truth (`tests/regression/`), plus `features/` and `benchmarks/`. |
| `test/` | Zig unit/integration test roots, wired in `build.zig`. |
| `test-results/` | Ceremony snapshot corpus: `latest.json`, `unit-tests.json`, prior boards. |
| `concepts/` | The membrane belief corpus — one belief per file, evolved through git. |
| `signals/` | World-model signals. |
| `challenges/` | The challenge ecology — replayable frames (including the repo-cleanup frame). |
| `wm/` | The world-model tool. |
| `models/` | World-model instruments (`commit_cadence`, `breath`). |
| `hooks/` | The membrane gate: `commit-msg` (World Model + Membrane sections) and `post-commit`. |
| `scripts/` | Harness and tooling: `regression_lib.sh`, `generate-status.js`, and friends. |
| `docs/` | Design docs (stale ones live here, swept by the 2026-08-31 purge). |
| `visual/` + `visual-identity.json` | Visual identity assets and their manifest. |
| `examples/` | Reference programs. |
| `benchmarks/` | Benchmark workloads. |
| `probes/` | Probe experiments (e.g. `r1`, concurrency calibration). |
| `demos/` | Demo projects. |
| `gauntlet/` | The cross-language gauntlet — a consumer that exercises `koruc`. |
| `invariants/` | The invariants manifest; `koruc` emits its backend here. |
| `todo/` | The residual manifest dir: `todo.kz` + `selftest.kz`. |
| `tools/` | Editor tooling (`koru-lsp`). |
| `skills/` | Root-level skills (the toolchain's active skills live in `.claude/skills/`). |
| `inbox/` | Held dispositions from mergebacks. |
| `docker-test/` | Docker-based test harness. |
| `lib/` | Runtime/backend space; currently holds an example. |
| `.claude/`, `.fallow/`, `.koru-studio/`, `.vercel/`, `.env.local` | Agent and environment state (private or local). |

Generated output (`.zig-cache/`, `zig-out/`, `zig-out-run-*/`, `status.json`) is
ignored and regenerable. Note the `.gitignore` is a whitelist: `!*/` and `!.*`
re-include every directory and dotfile at the root, so a new scratch directory
is tracked until it is explicitly named — name it, or it rides the next
ceremony commit.

## Links

- [Website](https://korulang.org)
- [X](https://x.com/korulang)
- [Learn](https://korulang.org/learn)
- [Status](https://korulang.org/status)
- [Discord](https://discord.gg/tYWvdrda8h)
- [Examples](https://www.github.com/korulang/koru-examples)
- [Benchmarks](https://www.github.com/korulang/koru-benchmarks)

## License

MIT
