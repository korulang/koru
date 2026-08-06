# 310_120 — the stdlib's default build steps run, end to end

This test exercises the stdlib's **own** default build steps (`compile_backend` →
`build`), overriding only `run`. It was pinned RED for the third defect below.
All three are fixed; `post.sh` now checks each step's artifact separately so a
regression names the link that broke.

## The three defects this test exists to hold down

1. **`~[default, depends_on(compile_backend)]` used `,`.** Annotations separate
   on `|`, so this parsed as ONE entry spelled `"default, depends_on(…)"`, matched
   nothing, and the dependency was dropped **silently**. Fixed in `6230e06e`;
   the silence itself is now refused by **PARSE007**
   (`annotation_parser.findInvalidSeparator`), which is what makes the class of
   defect non-recurring rather than this instance of it fixed.
2. **The `build` step ran `./zig-out/bin/main`.** Phase 1 emits
   `./zig-out/bin/backend`. Also fixed in `6230e06e`.
3. **Build steps ran in koruc's INVOCATION directory, not the OUTPUT directory.**
   `main.zig`'s step runner called `Child.run` with no `.cwd`, so every step
   inherited wherever koruc happened to be invoked from. Run from the repo root —
   which is how the harness runs — phase 1 could not see its own build file:

   ```
   error: failed to check cache: 'build_backend.zig' file_hash FileNotFound
   error: BuildStepFailed
   ```

## Why (3) looked like a design question, and why it was not

The escalation said "fixing the defaults breaks `310_033`, so which side moves is
a human call." That premise was false. **Nothing in the tree wanted the invocation
directory.** Three independent places already assumed the output directory:

- `koru_std/build.kz` — all three default scripts are output-dir-relative.
- `310_033`'s own `post.sh` — the harness `cd`s to the test directory
  (`regression_lib.sh:1710`) and the script reads a bare `steps.log`. Only that
  test's `input.k` used a repo-root path, and it was a workaround; its *checking*
  half had always been output-dir-relative, so the test disagreed with itself.
- `main.zig` — the package-install steps in the same function already passed
  `.cwd = output_dir` for `go mod download`. Build steps were the outlier.

So the contract was never *chosen*; a field was left unset. `executeBuildSteps`
now takes `output_dir` and every step runs there. `310_033`'s three paths
shortened to `steps.log`, which is what its verifier already expected.

**A build step's working directory is the output directory** — a step acts on the
emitted artifacts, which is where they live.

## What this test pins that 310_033 cannot

`310_033` overrides all three steps with echoes, so every script it runs is its
own: it proves ordering and `~[default]` precedence while executing none of the
stdlib's scripts. This test overrides only `run`, and `run` depends on `build`, so
a failure anywhere upstream means `run` never fires.

`post.sh` checks one artifact per step — `zig-out/bin/backend` for
`compile_backend`, `backend_tmp` for `build`, `chain.log` for `run` — rather than
one aggregate output, so a future break says which link went.

The `run` step writes a **file** rather than echoing. The harness drives the two
compilation passes itself (`regression_lib.sh:737`) and does not capture koruc's
stdout, so an echo is unobservable to any assertion — that mismatch, not the
build-step chain, was what kept this test red after the cwd fix landed.

## Also found while fixing this, and NOT this test's business

`koru_std/build_defaults.kz` is a **second copy** of these three default steps,
referenced by nothing (its header's claim that `build.kz` imports it is false —
nothing under `koru_std/`, `src/`, or `tests/` names it). It still carried defects
1 and 2 long after the live copy was fixed, because a forgotten duplicate cannot
be reached by the fix. Its contents are corrected; whether it should exist at all
is open.
