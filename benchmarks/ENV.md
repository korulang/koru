# Environment

Machine: Apple Silicon Mac (M-series, arm64), macOS Darwin 25.3.0.

| Tool | Version | Used for |
|---|---|---|
| Zig | 0.15.2 | Koru backend, baseline native code |
| Koru | e755b1aa (HEAD) | Koru implementations |
| dotnet | 9.0.100 | C# implementations |
| Python | 3.13.0 | Python implementations |
| Node | 25.9.0 | JavaScript implementations |
| Rust | 1.96.0-nightly | Rust implementations |
| Go | 1.26.3 | Go implementations (regex workloads) |
| OCaml | (not installed) | OCaml 5 tests parked — install required |

Build modes: ReleaseFast for AOT (Zig/Koru, Rust), default Release for managed runtimes (C#).
