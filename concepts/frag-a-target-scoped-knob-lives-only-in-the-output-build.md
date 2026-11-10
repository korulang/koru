---
type: belief
id: frag-a-target-scoped-knob-lives-only-in-the-output-build
provenance: korulang-site musl cross-compile, 2026-11-10 —
  KORU_BACKEND_LIBPATH leaked into the native backend build.zig template
  and broke --build=linux with "unknown cpu architecture" on libz.a
  whenever the backend cache missed. Fixed: env block now emitted only
  into the output build template.
ts: 2026-11-10
---

# A target-scoped env knob belongs only in the output build.zig (belief)

Emitted build files are per-artifact, and env vars that exist to steer
the *output* target must not be emitted into the backend build. The
backend exe is always native — it runs on the host at compile time — so
a cross-target `-L` path reaching it hands a foreign-arch archive to a
native link and fails with "unknown cpu architecture", an error that
names the archive and never the real mistake: the knob was applied to
the wrong artifact.

When adding an env-var-driven build input, ask which emitted build it
serves. Host-side and target-side are different audiences; a knob that
reads as global is usually scoped, and the scope is the bug when it
isn't written down.
