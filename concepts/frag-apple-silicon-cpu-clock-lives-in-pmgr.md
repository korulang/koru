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
path. The clock costs a.out ~1.3 MB of framework stubs (3724600 → 5064968).

Falsifier: Apple ships a populated public frequency API for Apple Silicon (a
sysctl that returns a value, or a documented host_processor_info field), or an
M-series release whose pmgr property no longer carries the frequency at
`[len-8..len-4]`.