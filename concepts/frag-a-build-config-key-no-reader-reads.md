---
type: belief
id: frag-a-build-config-key-no-reader-reads
provenance: esp32-c3 cross-compile session 2026-10-30 — added "cpu"
  forwarding (-Dcpu/-mcpu); the thumb blinky had documented the missing
  key as a follow-up
ts: 2026-10-30
tags: [koru, build, config, cross-compilation, toolchain]
---

# A build:config key nobody reads drops silently (belief)

`std/build:config` is an OPEN channel on the write side: its parser
registers any `"key": "value"` pair into `emitter_helpers.build_configs`,
no vocabulary check. The read side is closed — `host-build-zig` calls
`getBuildConfig` on a fixed set, today `{"target", "cpu"}`. A key outside
that set is a legal spelling with zero effect: the registry accepts it,
no diagnostic fires, and the build that comes out the other end is green
on a profile the config never asked for.

Measured, not hypothetical: `riscv32-freestanding` with no "cpu" resolves
Zig's arch default, which selects the double-float ABI — a green ELF
carrying FP instructions for silicon like ESP32-C3 (rv32imc/ilp32) that
has no FPU at all. The thumb blinky documented the same class for
cortex_m4 before the key existed: builds, links, won't run on the metal.

The corollary cuts at pin design. "It compiled" cannot tell a recognized
key from an ignored one — an ignored key also compiles, with the default
profile. Only an assertion inside codegen can distinguish arrival from
drop: 310_140 checks `featureSetHas(builtin.cpu.features)` (.m/.c
present, .d absent) rather than the artifact's existence. Assert the
feature set, not the exit code.

Open: whether `config` should REFUSE keys outside the recognized set.
Today they drop; refusal needs the vocabulary enumerable at the
registration site, which lives one hop earlier than the reader that
knows it. If a third key lands, this question is still open.
