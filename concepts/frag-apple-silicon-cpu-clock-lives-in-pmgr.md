---
type: belief
id: frag-apple-silicon-cpu-clock-lives-in-pmgr
provenance: diagnosed 2026-08-19 while fixing Ward's 0.0 GHz clock read; compared against ward-rs (sysinfo) and Java OSHI on the same machine
ts: 2026-08-19
---

# On Apple Silicon Darwin, the CPU clock is not in sysctl — it lives in the power manager's P-state table (belief)

`hw.cpufrequency` (and `_max`/`_min`) exist on this Darwin but answer empty —
the oid reports nothing on M-series, so any program that trusts it renders a
0.0 clock. Java's OSHI reads the same oid and shows `0 MHz`. The real max
frequency is the `voltage-states5-sram` CFData property on the `pmgr` service
under `AppleARMIODevice` in IOKit: a table whose u32 at `[len-8..len-4]` is the
max P-state in Hz (3504000000 on an M2 Pro) and whose final four bytes are the
voltage word. Same source as psutil PR 2222 and sysinfo's macOS backend.

Ward now reads it that way (`$mod.cpuClockMHz()` in examples/ward/main.kz) and
reports 3.5 GHz, agreeing with ward-rs. Reaching the property needs IOKit and
CoreFoundation, which the direct `zig build-exe` fallback cannot link — Ward is
the first program in this tree to use the Stage-D `build_output.zig` user-deps
path, declared as `std/build:requires` in main.k.

COST CORRECTED 2026-08-19 (same day, measured): the two frameworks add 32
bytes of stubs — the earlier "5.06 MB a.out" was Zig 0.15 building the output
binary in Debug (standardOptimizeOption with a preferred mode returns Debug
unless `--release=fast` is passed; the generated build_output.zig comment said
ReleaseFast and the pipeline passed no flag). Ward builds at 3,725,944 bytes
at ReleaseFast — effectively the pre-fix 3,724,600. The clock read is
~1.3 KB of binary.

RESOLVED 2026-08-19: emit_build_zig.zig was the stale template (only the
build_output.zig path—programs with std/build:requires—was affected; the
direct `zig build-exe` path already defaulted ReleaseFast with a --debug
opt-out). It now emits `b.option(OptimizeMode, "optimize", ...) orelse
.ReleaseFast` and takes the debug flag at generation time. Every Koru output
binary builds fast-and-lean by default; the belief now lives in the emitter,
not this file.

Falsifier: Apple ships a populated public frequency API for Apple Silicon (a
sysctl that returns a value, or a documented host_processor_info field), or an
M-series release whose pmgr property no longer carries the frequency at
`[len-8..len-4]`.