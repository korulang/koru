// Pins that the STDLIB DEFAULT build steps actually run — not merely that
// overriding them works.
//
// 310_033 already covers `~[default]` precedence and dependency ordering, but it
// overrides compile_backend, build AND run with echoes. Every script it executes
// is its own, so it is structurally incapable of noticing that the default
// `build` step was broken: koru_std/build.kz ran `./zig-out/bin/main` while
// phase 1 emits `./zig-out/bin/backend`. Anyone attaching `[depends_on(build)]`
// to the real default got:
//
//     sh: ./zig-out/bin/main: No such file or directory
//     error: BuildStepFailed
//
// It stayed latent because the declarative step pipeline only engages once a
// program declares a step of its own, which almost nothing does.
//
// This test overrides ONLY `run`, so `build` and `compile_backend` are the
// stdlib's own scripts. Reaching this program's output at all means the real
// default chain executed end to end.

import std/build
import std/io

[depends_on(build)] std/build:step(name: "run") {
    echo "default chain reached run"
}

std/io:print.blk {
    unreachable unless the defaults ran
}
