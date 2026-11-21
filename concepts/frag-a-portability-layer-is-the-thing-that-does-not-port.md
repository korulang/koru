---
type: belief
id: frag-a-portability-layer-is-the-thing-that-does-not-port
provenance: Orisha's pump is written on Zig's std.net. `zig build-lib -target x86_64-freestanding` refuses it outright — std.posix has no sockaddr there. The extern-C form compiles to 1,258 bytes on the same target and serves HTTP from a Unikraft unikernel. Measured 2026-08-08, examples/unikraft-net
ts: 2026-08-08
---

# A portability layer is the thing that does not port

`std.net` exists so a program need not care which operating system it runs on.
That is exactly why it cannot follow a program off the operating systems it
knows. A portability abstraction is a *union of the hosts it was written for*,
and a target outside that union is not a gap in the abstraction — it is outside
its domain, and the failure is total rather than partial.

On `x86_64-freestanding` the error is not "sockets are unavailable"; it is
`struct 'posix.system__struct_395' has no member named 'sockaddr'`, thrown while
resolving a type. Nothing above `std.posix` can be named, so there is no reduced
subset to fall back on. Meanwhile **the sockets are right there** — `posix-socket`
and lwip put `socket`, `bind`, `listen`, `accept` in the image as ordinary C
symbols in the same address space. The capability was never missing. Only the
abstraction over it was.

**So the layer that promises to hide the platform is the layer that must be
per-platform.** This inverts the instinct that says "write against the portable
API and the port is free". The right shape is the opposite: name the seam, admit
each platform writes its own body, and let the parts *above* the seam — parsing,
routing, response shaping — be the code written once. Orisha reached this shape
by accident, splitting its loop out behind a per-platform pump before anyone had
proved the unikernel needed it; the split turns out to be the only shape that can
work, not a tidy-up.

The tell that generalizes: **when a "portable" dependency is the only thing
standing between you and a target, the dependency is the platform assumption.**
Not the syscalls, not the toolchain, not the target's poverty. Something chose a
union of hosts on your behalf, and the choice only becomes visible at the edge of
it.

The corollary is about routes. There is always a second path that keeps the
portable abstraction working — here, compile to `linux-musl` and run under a
syscall shim or an ELF loader. It is easier, it is defensible, and it costs the
whole point: 164 KB with no Linux ABI becomes 1.78 MB with one. **A route that
preserves an abstraction by restoring the platform it assumed has not ported
anything.** It has re-created the host and run there. Compare what the artifact
IS, not whether it runs.

**And "freestanding" is itself a union.** Measured 2026-10-15: the emitted
`__koru_backing` sent every `os.tag == .freestanding` program to `__koru_bare`
— the extern `posix_memalign`/`free` road this frag celebrates on Unikraft,
where the image really does carry `T malloc`/`T free`. On wasm32-freestanding
those symbols are *imports the host must supply*, and Vercel's wasm runtime
supplies exactly one (`env.time`) — every invocation died at instantiate,
`LinkError: Import #1 module="env" function="free"`, until `__koru_backing`
split freestanding on `cpu.arch.isWasm()`: wasm gets `page_allocator`, which
Zig resolves to `WasmAllocator` (`memory.grow`, self-contained, no imports);
the extern road stays for the boards that own their symbols. The externs had
been dead-stripped for months — `ce2b015ff` making compress/string buffers
answer to `koru_allocator()` is what made `free` reachable and surfaced the
hole. A fallback measured on one freestanding host is not measured on
freestanding.

**The union also excludes the host.** Measured 2026-11-21 on Windows 10 +
zig 0.15.1: `zig build` of koruc itself refused three times — `posix.getenv`
is a `compileError` there (WTF-16 env), `std.posix.SIG` has no `KILL`, and
`File.chmod` is `fchmod`, unsupported by the target OS. The emitted side was
worse because it compiled quietly: `io.kz`'s writer template emitted
`posix.write(fd: i32)` for every hosted target, but on Windows the fd slot
carries a HANDLE, so the program would have written to a number, not a
stream — fixed as this frag prescribes, a per-platform arm
(`GetStdHandle`/`WriteFile`) above the shared splicing. And one that was not
even a posix call: `emitInvocationMetaFields` wrote `loc.file` raw into a
Zig string literal, so a `W:\src\...` path produced `"\s"`, `"\k"` — "paths
are strings" is itself a POSIX-shaped assumption; the escape helper existed
ten lines up and the call site just never met a host whose paths need it.
koru's portability evidence had always been about *targets* — wasm,
unikernel, pinned glibc — while the toolchain's own host list was a union of
one. **The host is a target too; a target list that omits it leaves the
whole compiler unmeasured.**

Related: [[frag-a-diagnostics-hint-is-a-claim-not-a-tested-path]] — both are
about trusting a stated surface over an exercised one.
