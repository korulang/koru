---
type: belief
id: frag-foreign-exceptions-die-at-the-wrapper-boundary
provenance: design session with Lars 2026-11-06 (devin-cli) — Itanium C++ ABI EH review while asking whether Koru can link C++ shared/static libraries; Zig 0.15.2 unwind-table emission measured this session; ruled wrapper-side conversion, no language/std surface
ts: 2026-11-06
tags: [koru, ffi, exceptions, unwind, c++, wrapper]
---

# Foreign exceptions are converted at the wrapper's shim — they never unwind through Koru (belief)

A throwing foreign library — the C++ `.so`/`.a` case — is the **wrapper
package's** problem, the same place `curl` already maps libcurl's error
returns into `| err e` payloads. The conversion happens inside the
wrapper's own `extern "C"` shim: `try { foreign_call() } catch(...) {
return {code, what()} }` — the exception becomes data before it touches a
Koru frame, and the implproc produces `=> foreign msg` on a `?!foreign`
branch the `tor` declares like any other panic branch. Callers handle it,
`std/panic:catch` pillows it, supervision restarts it, or it traps loudly —
the existing machinery consumes it unchanged.

The catch *placement* is the load-bearing decision, not a detail. Inside
the shim, no Koru frame is ever unwound: `defer`, custody discharge, and
obligation settlement all run normally because control returns through
ordinary Koru branches. A catch at the proc or `main` boundary unwinds
pad-less emitted frames and skips every in-flight cleanup — the exact
semantics the obligation model exists to prevent. Coarse catches are
airbags, not the mechanism.

## Why not the surfaces that were considered

- **No runtime-installable global C++ handler exists.** In the Itanium
  ABI the personality routine is per-frame, baked into `.eh_frame` at
  compile time; `std::set_terminate` sees only already-fatal exceptions
  and cannot resume. "Install a general handler" is real only as emitter
  work — a Koru personality routine plus LSDA on every frame — deferred
  until a real C++ `.so` demands it.
- **`?!foreign` on the `tor` is already the whole contract.** It is in
  the signature, produce-matching refuses undeclared produces, and the
  catch/supervision consumers already exist. An annotation synthesizing
  the branch from impl detail inverts declare/implement and is unstable
  across impls.
- **`std/foreign` stays inspection-only** (its 2026-09-04 ruling); exception
  translation is wrapper work — not a new verb there, and no `std/cpp`
  module.
- **Demand is unproven.** Well-behaved C++ libraries ship `extern "C"`
  façades precisely to avoid this; the C++-native `.so`/`.a` niche (VFX,
  game middleware, ML native) has not appeared in `requires.system` —
  every current entry is C.

## What would change this

A real C++ binary landing in `requires.system` reopens the wrapper-side
work, still not the language: a shim TU compiled at build time, the C++
runtime linked, `what()` plus a type tag marshaled into the payload.
If foreign exceptions become frequent enough that per-callsite shims are
boilerplate, the emitter-personality option — the only design where
foreign unwind itself can run Koru cleanup — is the revisit. A top-level
guard around the emitted `main` flow dispatch is mechanically possible
(Zig 0.15.2 emits `.eh_frame`, measured on ELF and Mach-O this session)
but coarse and cleanup-skipping; it is the airbag shape, kept in reserve.

## Open

- Payload shape unruled: `what()` string alone, or a shim-side
  `typeid`→enum tag beside it.
- The branch name itself is unruled — `foreign` vs `cpp` vs `native`.
- Whether top-level flows are independent steps or one program decides
  if a per-flow guard could ever continue past a dead flow — a language
  ruling, only live if the airbag is ever built.

Relates to [[frag-panic-declinability-is-a-checker-stance]] (the `?!`
kind-space this rides, unchanged) and the `std/foreign` airlock ruling
inside [[frag-type-system-design]] (inspection-only stands; this belief
lives one layer out, in the wrapper).
