# libukrandom: Cryptographically Secure Randomness

This library implements a cryptographically-secure PRNG (CSPRNG).
Secure randomness is available to applications via the `getrandom()` syscall (`CONFIG_LIBUKRANDOM_GETRANDOM`), and via `/dev/random`, `/dev/urandom`, and `/dev/hwrng` (`CONFIG_LIBUKRANDOM_DEVFS`).
Unikraft libraries can obtain secure randomness via the [libukrandom API](https://github.com/unikraft/unikraft/blob/staging/lib/ukrandom/include/uk/random.h).

The CSPRNG is based on Daniel J Bernstein's [ChaCha20](https://cr.yp.to/chacha/chacha-20080128.pdf).
Selecting `CONFIG_LIBUKRANDOM_TEST` runs the IETF tests described in [RFC8439](https://datatracker.ietf.org/doc/html/rfc8439).

## Seeding the CSPRNG

The PRNG is normally seeded by a hardware TRNG.
Currently this is provided by `drivers/ukrandom/lcpu/` which provides CPU-generated randomness.

On systems that don't feature a hardware TRNG, the host / loader can alternatively provide a seed via Unikraft's command-line, or on `arm64` systems via the device-tree.

To provide a seed via the command line:

* Select `CONFIG_LIBUKRANDOM_CMDLINE_SEED`
* Pass the `random.seed` option to the command-line, with a 256-bit seed formatted as an array of 32-bit words.

To provide a seed via the device-tree:

* Select `CONFIG_LIBUKRANDOM_DTB_SEED`
* Pass a 256-bit seed formatted as an array of 32-bit words to the `/chosen/rng-seed` node.

If you are populating the seed on the host, you can generate secure randomness via `/dev/urandom`.

**Example:** Passing a seed via the command-line on QEMU

```text
SEED=$(hexdump -vn32 -e'8/4 "0x%08X "' /dev/urandom)
```

Then invoke QEMU as usual, passing the generated seed to the command line:

```text
-append "random.seed=[${SEED}] --"
```

**Notice:**
* The command-line and dtb options have higher precedence over seeding via a hardware TRNG.
* The command-line option involves secuirty risks (e.g. the seed is available in the host's procfs / ps).
  It is the responsibility of the loader / host to protect the seed.
