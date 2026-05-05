# Embedded Blinky Shootout

The smallest possible firmware that does something visible — toggle PA5 on
an STM32F401RE so the on-board LED blinks — implemented in five languages
on the same target, cross-compiled and measured the same way.

## The claim

Embedded RTOS infrastructure exists because C couldn't carry the
type-level guarantees that would obviate runtime coordination. Stronger
type systems — phantom states for FSMs, obligations for resource
lifecycle, variant dispatch for target portability — make the kernel a
relic. The job a runtime kernel does, a compile-time type system can do
in zero output bytes.

This shootout is the smallest artifact that demonstrates the property:
side-by-side `.elf` files, full disassembly, identical workload, same
target, measured the same way. Read the bytes.

## The workload

Toggle PA5 (LD2 on Nucleo-F401RE) at roughly 1 Hz. No interrupts, no
timers — busy-loop delay is fine. The point is the smallest workload
that exercises peripheral access; not a meaningful benchmark of *speed*,
a measurement of what each language's "do something on hardware" baseline
contains.

## The target

- **Board:** ST Nucleo-F401RE (~$15, widely available)
- **MCU:** STM32F401RE (Cortex-M4F, 84 MHz, 512 KB flash, 96 KB SRAM)
- **Triple:** `thumbv7em-none-eabihf` / `-mcpu=cortex_m4`
- **LED:** PA5 (GPIOA pin 5), driven push-pull

## Implementations compared

| Language | Style                                | Crates / deps                              |
|----------|--------------------------------------|--------------------------------------------|
| C        | bare-metal, no RTOS, hand linker.ld  | newlib-nano (libgcc only), no startup code |
| Zig      | freestanding, hand vector table      | none — pure `zig build-exe -target ...`    |
| Rust     | naive `embedded-hal`                 | `cortex-m`, `cortex-m-rt`, `stm32f4xx-hal` |
| Rust     | Embassy async                        | `embassy-stm32`, `embassy-executor`        |
| Koru     | idiomatic + `cortex_m4` variant      | none — variants resolve at compile time    |

## Methodology

1. Cross-compile each implementation for `thumbv7em-none-eabihf` with
   release-size optimization (`-O ReleaseSmall`, `-Os`, `opt-level = "z"`).
2. Strip symbols, disable unwind tables, no PIC.
3. Run `arm-none-eabi-size` and `bloaty` on the resulting `.elf`.
4. Capture per-section bytes (`.text`, `.rodata`, `.bss`, `.data`).
5. Render a comparison table to `results.md`; raw data to `results.json`.

## What we measure (and don't)

**Measured:** binary footprint per section. This is reproducible without
hardware, deterministic across runs, and the headline number for embedded
firmware constraints (flash ROM is finite; RAM is finiter).

**Not measured here:** runtime speed, latency, or energy. Those require
real hardware in the loop and are explicitly out of scope for this test.
The point isn't "Koru is faster" — it's "Koru's binary contains less."

## Comparison-creep disclaimer

"Naive Rust" means `embedded-hal` with `stm32f4xx-hal`. "Embassy" is
included because it's the runtime stack the recent Ariel OS / VDP study
([arXiv:2604.25679](https://arxiv.org/abs/2604.25679)) used as its Rust
firmware reference. Other Rust embedded stacks (RTIC, Hubris, TockOS)
exist; we picked the two most representative of common production
choices.

The C reference is intentionally bare-metal (no FreeRTOS, no Zephyr) —
that's the most generous comparison for C. If we beat naive C on
binary size, the win is structural, not accidental.

## Skip-by-default

This test requires a cross-compile toolchain (`arm-none-eabi-gcc`,
`bloaty`, plus rustup with `thumbv7em-none-eabihf` target). On systems
missing the toolchain, `run.sh` exits 0 with a "skipped: missing
toolchain" message rather than failing the regression run.

## What this test passes / fails

This is currently scaffold. Pass criteria are TBD once we have a
first set of measurements. Likely shape:

- Koru `.text` is smaller than naive embedded-hal Rust by some margin.
- Koru `.text` is smaller than Embassy Rust by a *large* margin.
- Koru `.text` is within a small budget of naive C and naive Zig
  freestanding (since all three have no runtime to begin with — the
  delta will be in linker / startup overhead).

Failing cases are still useful data — even "Koru ties bare-metal C and
beats Rust by an order of magnitude" is the receipt the kernel-as-relic
thesis needs.

## File layout

```
embedded_blinky/
├── README.md           # this file
├── run.sh              # comparison harness
├── results.json        # raw measurement output
├── results.md          # human-readable comparison table
├── koru/
│   └── blinky.kz       # the Koru implementation
└── reference/
    ├── blinky.c        # bare-metal C
    ├── linker.ld       # C linker script
    ├── blinky.zig      # freestanding Zig
    ├── rust_naive/     # bare embedded-hal Rust
    │   ├── Cargo.toml
    │   ├── memory.x
    │   └── src/main.rs
    └── rust_embassy/   # Embassy async Rust
        ├── Cargo.toml
        ├── memory.x
        └── src/main.rs
```
