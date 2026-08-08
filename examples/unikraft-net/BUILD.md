# Koru serving HTTP from a Unikraft unikernel

The network successor to `examples/unikraft/BUILD.md`, which booted Koru in a
unikernel and printed. This one **accepts TCP connections and answers HTTP**,
still with no Linux ABI and no syscall shim.

Measured 2026-08-08 on macOS/arm64, kraftkit 0.12.15, Unikraft `stable` (0.21.0
"Ijiraq"), lib-lwip `stable`, qemu-system-x86_64 under TCG.

## What it proves

A Koru program reaches the network the same way `std/io` already reaches
nolibc's `fputs`: **as plain C symbols resolved at link time inside the image.**
Three `curl`s against the host-forwarded port each returned the body, and the
guest console printed Koru's own `served 3` through `std/io:print.ln`.

```
$ curl -i http://127.0.0.1:18333/
HTTP/1.1 200 OK
Content-Length: 18
Connection: close

hello from koru
```
```
en1: Set IPv4 address 10.0.2.15 mask 255.255.255.0 gw 10.0.2.2
koru unikernel: served 3
```

## Why not Zig's `std.net`

It cannot exist on this target, and that is a hard compile error rather than a
preference:

```
$ zig build-lib probe.zig -target x86_64-freestanding
std/posix.zig:156:28: error: struct 'posix.system__struct_395' has no member named 'sockaddr'
pub const sockaddr = system.sockaddr;
referenced by: net.Address
```

`std.posix` has no syscall layer on `freestanding`, so every hosted networking
abstraction above it is unavailable. The extern-C form compiles to a 1,258-byte
archive on the same target. **This is the whole reason a platform pump seam
exists**: the same `run` tor cannot be written once for kqueue, epoll and a
unikernel.

## Build

```sh
koruc serve.kz                              # -> output_emitted.zig
zig build-lib wrapper.zig \
    -target x86_64-freestanding -O ReleaseSmall \
    -fno-stack-protector -femit-bin=libkoruapp.a
UK_CFLAGS="-std=gnu17" kraft build --arch x86_64 --plat qemu --no-prompt
```

```sh
qemu-system-x86_64 -kernel .unikraft/build/ukserve_qemu-x86_64 \
  -cpu 'qemu64,+pdpe1gb,+rdrand,+rdseed,-vmx,-svm' \
  -m 64M -nographic -no-reboot -display none -parallel none \
  -netdev user,id=n0,hostfwd=tcp::18333-:8080 \
  -device virtio-net-pci,netdev=n0
```

## Measured

| | |
|---|---:|
| Koru freestanding static archive | 5,736 B |
| bootable unikernel image | 555,560 B |
| the same image without networking (`examples/unikraft`) | 164,544 B |
| what lwip + posix-socket + virtio-net cost | ~391,016 B |
| RAM floor (boots and serves) | 6 MB |
| RAM floor (fails) | 5 MB |

**The floor is set by the network stack, not by Koru.** At 5 MB the virtio
driver cannot allocate its virtqueue (`-12`, ENOMEM), lwIP then fails to attach
the device, and the program's own `failed` arm reports `FAILED at socket` —
correctly, because with no interface there is no socket to open. Nothing crashes
and nothing lies; the error names the first call that could not be satisfied.

For contrast the print-only image (`examples/unikraft`) floors at 2 MB. So
networking costs about 4 MB of RAM on top of its ~391 KB of image.

Measured by bisection at 64/32/16/8/6/5/4/3 MB, each boot serving a real request
over the host-forwarded port; 6 MB confirmed twice.

## Traps

Everything in `examples/unikraft/BUILD.md` still applies (`-std=gnu17`,
`--no-prompt`, stale `.config.<name>`). Three more:

- **There is no `sin_len` byte on this platform.** Unikraft's nolibc imports
  musl's `netinet/in.h`, where `sockaddr_in` is `{u16 family; u16 port; u32
  addr; u8 zero[8]}`. Writing the BSD layout (`{u8 len; u8 family; ...}`) puts
  `0x0210` where the family belongs; `socket` and `listen` both succeed and
  `bind` fails, so the error points at the wrong call. Read
  `.unikraft/unikraft/lib/nolibc/musl-imported/include/netinet/in.h` rather than
  reasoning from a platform you know.
- **`CONFIG_LWIP_DHCP` is what makes QEMU user-mode networking work.** SLIRP
  runs a DHCP server and hands out 10.0.2.15; without DHCP the interface comes
  up with no address, `bind`/`listen` still succeed, and the host's port forward
  connects to nothing. Every log line reads healthy.
- **lib-lwip's newest PINNED version targets Unikraft 0.20.0** while we build
  0.21.0. The `stable` channel is a branch tarball rather than a pinned gitsha
  and builds clean — so ask for `version: stable`, not a version number.

## Known-not-done

- **Orisha still cannot use this.** Its pump (`orisha/lib/pump.kz`) has two
  variants, `|zig` (kqueue) and `|epoll`, and both are built on `std.net` /
  `std.posix`. The unikernel needs a third, `|unikraft`, written against these
  extern symbols. That variant is the next piece of work, and the compiler
  change that makes it selectable — an effect arm and a proc variant coexisting
  — landed 2026-08-08 in `e0a366c4`.
- **No lift.** `serve.kz` declares the seven socket functions inline. The lift
  (`unikraft/socket`, beside `unikraft/net`) would put the ordering —
  `socket → bind → listen → accept`, and every fd closed — behind phantom
  states. `unikraft/net` wraps `uknetdev`, which is the raw-frame layer and the
  wrong altitude for a server.
- **The effect arm is untested here.** This program loops and returns; Orisha's
  `run` fires `! arrived *Exchange` per request. That splice is pinned on the
  hosted target (370_011) and has never been run freestanding.
- **lwip's threading mode is the default** (`LWIP_THREADS`, a stack thread).
  Whether Orisha's single-loop pump wants `LWIP_NOTHREADS` is unexamined.
- **`.note.GNU-stack` warning at link:** the Zig archive requests an executable
  stack. Harmless here, unexamined.
