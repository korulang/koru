# 310_120 — pinned RED on purpose: build steps run in the wrong directory

This test exercises the stdlib's **own** default build steps (`compile_backend` →
`build`), overriding only `run`. It passes when `koruc` is invoked from the
directory holding the emitted files, and fails under the harness, which invokes
from the repo root:

```
error: failed to check cache: 'build_backend.zig' file_hash FileNotFound
error: BuildStepFailed
```

`build_backend.zig` exists — in this test's directory. The step never saw it.

## Cause

`src/main.zig:4976` runs each step with

```zig
std.process.Child.run(.{ .allocator = allocator, .argv = &[_][]const u8{ "sh", "-c", step.script } });
```

There is no `.cwd`, so every step inherits koruc's invocation directory. The
stdlib's defaults (`koru_std/build.kz`) are written against the *output*
directory — `zig build --build-file build_backend.zig`,
`./zig-out/bin/backend backend_tmp`, `./backend_tmp` are all relative.

## Why this is a design question and not a one-line fix

The two sides of the contract disagree, and neither is documented:

- **`koru_std/build.kz` assumes cwd = the output directory.** All three default
  scripts are relative to it.
- **`310_033_default_with_dependencies` assumes cwd = the repo root.** It writes
  `tests/regression/300_ADVANCED_FEATURES/310_COMPTIME/310_033_default_with_dependencies/steps.log`
  — a repo-root-relative path. That test passes today, and it is almost certainly
  a workaround its author reached for after hitting exactly this.

So adding `.cwd = output_dir` fixes the defaults and **breaks 310_033**. Which
side moves is a call about what a build step's working directory *means*, and it
belongs to the human, not to whichever artifact is easier to edit.

## What is already fixed (and is not this bug)

`6230e06e` repaired two real defects in the same three lines of
`koru_std/build.kz`, both verified in both directions:

1. `~[default, depends_on(compile_backend)]` used `,` where annotations separate
   on `|`. The dependency was dropped **silently** — no diagnostic.
2. The `build` step ran `./zig-out/bin/main`; phase 1 emits `./zig-out/bin/backend`.

With those fixed and the cwd correct, the chain runs end to end and this test
prints `default chain reached run`. Reproduced by hand in a scratch directory.

## Also unfixed, and cheaper than the above

An invalid annotation separator emits **no diagnostic**. `~[a, b]` silently
becomes something that is not two annotations. Failing loud there would have made
defect 1 a five-second fix instead of a session.
