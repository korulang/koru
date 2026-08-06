// Pins that the STDLIB DEFAULT build steps actually run — not merely that
// overriding them works.
//
// 310_033 already covers `~[default]` precedence and dependency ordering, but it
// overrides compile_backend, build AND run with echoes. Every script it executes
// is its own, so it is structurally incapable of noticing that a default step is
// broken. Two defects hid there for exactly that reason:
//
//   1. `~[default, depends_on(compile_backend)]` used `,` where annotations
//      separate on `|`, so the dependency was DROPPED — silently, until PARSE007
//      started refusing that spelling.
//   2. The default `build` step ran `./zig-out/bin/main` while phase 1 emits
//      `./zig-out/bin/backend`.
//
// And a third, which is why this test was pinned red rather than merely failing:
// build steps inherited koruc's INVOCATION directory instead of the OUTPUT
// directory, so the stdlib's own output-dir-relative defaults only worked when
// you happened to invoke koruc from the output directory. Run from the repo root
// — which is how the harness runs — phase 1 could not find `build_backend.zig`:
//
//     error: failed to check cache: 'build_backend.zig' file_hash FileNotFound
//     error: BuildStepFailed
//
// This test overrides ONLY `run`, so `build` and `compile_backend` are the
// stdlib's own scripts, and `run` depends on `build` — a failure anywhere in the
// chain means `run` never fires. post.sh then checks each step's own artifact
// individually, so a regression names which link broke rather than just "output".

import std/build
import std/io

// Writes a file rather than echoing: the harness drives the two compilation
// passes itself (regression_lib.sh:737) and does not capture koruc's stdout, so
// an echo to the terminal is unobservable to any assertion. The path is bare
// because a build step's working directory IS the output directory.
[depends_on(build)] std/build:step(name: "run") {
    echo "default chain reached run" > chain.log
}

std/io:print.blk {
    unreachable unless the defaults ran
}
