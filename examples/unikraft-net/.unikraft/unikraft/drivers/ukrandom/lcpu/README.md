# CPU-generated Randomness

This library implements a Unikraft driver that provides CPU-generated randomness via the [libukrandom driver API](https://github.com/unikraft/unikraft/blob/staging/lib/ukrandom/include/uk/random/driver.h).

Arm introduces secure randomness on `Armv8.5-A` via the `RNDR` / `RNDRRS` instructions, on processors that implement `FEAT_RNG`.
For more info, see the [Arm Architecture Reference Manual](https://developer.arm.com/documentation/ddi0487).
This driver implements `random_bytes()` using `RNDR` and `seed_bytes()` using `RNDRRS`.
`seed_bytes_fb()` falls back to `RNDR`, if `RNDRRS` fails to provide entropy during the call.

Intel provides cryptographically secure randomness via `RDRAND` / `RDSEED`.
`RDRAND` was introduced at 2012 with Intel Ivy Bridge / AMD Bulldozer, and `rdseed` was first part of Intel Broadwell / AMD Zen.
Information on `RDRAND` / `RDSEED` is provided at Intel's [Digital Random Number Generator (DRNG) Software Implementation Guide](https://www.intel.com/content/www/us/en/developer/articles/guide/intel-digital-random-number-generator-drng-software-implementation-guide.html).

This driver implements `random_bytes()` using `RDRAND`, and `seed_bytes()` using `RDSEED`.
If `RDSEED` is not detected during probe, `seed_bytes()` falls-back to `RDRAND`.
Similarly, `seed_bytes_fb()` falls back to `RDRAND`, if `RDSEED` is not detected, or if `RDSEED` fails to provide entropy during the call.

### QEMU with KVM acceleration / Firecracker / Baremetal

To determine whether the host CPU provides randomness you can check `/proc/cpuinfo`:
* **arm64**: `cat /proc/cpuinfo | grep rng`.
  Alternatively, you can refer to Marcin Juszkiewicz's [list of AArch64 SoC Features](https://gpages.juszkiewicz.com.pl/arm-socs-table/arm-socs.html).
* **x86_64**: `cat /proc/cpuinfo | grep rdrand` and `cat /proc/cpuinfo | grep rdseed`

### QEMU with emulation (TCG)

Make sure you use a version of QEMU that implements CPU-provided randomness on TCG:

* `arm64`: QEMU introduces `RNDR` / `RNDRRS` on TCG in [QEMU 4.1](https://wiki.qemu.org/ChangeLog/4.1)
* `x86_64`: QEMU introduces `RDRAND` support on TCG in [QEMU 4.1](https://wiki.qemu.org/ChangeLog/4.1), and `RDSEED` in [QEMU 8.1](https://wiki.qemu.org/ChangeLog/8.1).

You should also select a suitable CPU on QEMU.
Passing `--cpu=max` is a safe choice.
