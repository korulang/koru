# Koru as a native Unikraft unikernel

Reproduction recipe for the image measured in `bbef1895`. Not a tutorial — the
exact commands, so the numbers can be re-derived rather than believed.

Measured 2026-08-05 on macOS/arm64, kraftkit 0.12.15, Unikraft 0.21.0 "Ijiraq",
qemu-system-x86_64 under TCG (no KVM — so there is **no boot-time number here**;
that needs x86 hardware).

## The seam

Five files, and every one of them is something a `~unikraft:config` block could
eventually generate:

| file | role |
|---|---|
| `hello.kz` | the Koru program — plain `std/io:print.ln`, nothing platform-specific |
| `wrapper.zig` | C-ABI entry: exports `koru_main`, calls the emitted flow |
| `main.c` | Unikraft's boot path calls `main`; `main` calls `koru_main` |
| `Makefile.uk` | registers the app and its static archive (`APPKORU_ALIBS-y`) |
| `Kraftfile` | the Kconfig deltas |

## Build

```sh
koruc hello.kz                              # -> output_emitted.zig
zig build-lib wrapper.zig \
    -target x86_64-freestanding -O ReleaseSmall \
    -fno-stack-protector -femit-bin=libkoruapp.a
UK_CFLAGS="-std=gnu17" kraft build --arch x86_64 --plat qemu --no-prompt
```

```sh
qemu-system-x86_64 -kernel .unikraft/build/koru_qemu-x86_64 \
  -cpu 'qemu64,+pdpe1gb,+rdrand,+rdseed,-vmx,-svm' \
  -m 32M -nographic -no-reboot -display none -parallel none
```

→ `print.ln, from koru, inside a unikernel`

## Measured

| | |
|---|---:|
| Koru freestanding static archive | 2,968 B |
| bootable unikernel image | 164,544 B |
| RAM floor (boots) | 2 MB |
| RAM floor (fails) | 1.5 MB |
| build, from clean | ~15 s |

`LIBSYSCALL_SHIM` and `LIBVFSCORE` are both unset in the built config: there is
no Linux ABI in this image and no syscall shim. `fputs` is a direct call into
nolibc in the same address space.

For contrast, the same Koru program via `app-elfloader` (the binary-compat route,
which *does* keep the Linux ABI) is a 1,785,736-byte image with a 5 MB floor.

## Three traps, all of which cost time

- **`UK_CFLAGS="-std=gnu17"` is required.** GCC 16 defaults to `gnu23`, where
  `(*ctorfn)(argc, argv)` in Unikraft's `lib/ukboot/boot.c:489` is a hard error.
- **`--no-prompt` is required.** Without it `kraft build` blocks forever on
  `project already configured, are you sure you want to rerun the configure step
  [Y/n]`, which reads exactly like a slow toolchain. It is not: the build is ~15 s.
- **`.config.<name>` outlives `rm -rf .unikraft/build`.** Delete it too, or a
  stale Kconfig silently drives the next build. A killed build also leaves
  zero-byte `.ld.o` files that then fail as "input file is empty" forever.

## Why `CONFIG_STACK_SIZE_PAGE_ORDER: '6'`

Unikraft's default is order 4 — 16 pages, exactly 64 KB. `__printInterpolate`
emits a 65,536-byte format buffer on the stack, so any Koru print overflows the
entire boot stack and traps. Order 6 gives 256 KB. This costs zero image bytes.

The honest reading: Koru's print is sized for a hosted 8 MB stack and nobody had
ever asked what it costs on a target that does not have one.

## Known-not-done

- No HTTP server. Orisha's examples are pre-migration (`~event`, `$std`,
  `std.io:println`) — a migration job, not a boot job.
- `OPTIMIZE_LTO` breaks the link: `--gc-sections` drops the C exception handlers
  that only the interrupt-vector *assembly* references. `OPTIMIZE_DEADELIM`
  alone is fine and is worth 24,832 bytes.
- 41,920 bytes of the image (25%) is `.eh_frame` from CFI directives in platform
  assembly, unreachable by any C flag. `objcopy --remove-section` corrupts the
  image; it needs a linker-script `/DISCARD/`.
- `CONFIG_LIBUKBOOT_INITSCHED: 'n'` and `CONFIG_LIBUKSCHEDCOOP: 'n'` are
  silently ignored — 99 KB of scheduler objects stay in. Kconfig reported no
  error. That, and the `.eh_frame`, are the two concrete arguments for deriving
  the config from the program's obligation set instead of ticking boxes.
