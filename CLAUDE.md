# Project Guide

A guide for agents working on Koru. Interim documentation — the test suite is
the evolving ground truth.

## You are working on a compiler

Koru is a compiler. Shortcuts cascade. When you hit a problem, stop and ask —
don't silently work around it.

## Never run destructive git commands without explicit approval

Don't run any of these without an explicit go-ahead from the user:

- `git clean` (any variant)
- `git reset --hard`
- `git checkout .` / `git restore .`
- `git rebase` with force
- `git push --force`
- Any command that deletes or overwrites repository files

If you think a destructive command is necessary: describe what you'd run and why,
and wait for approval.

## Ask before changing repository structure

Don't modify `.gitignore`, don't delete repository files, and don't run
unexpected `git add` / `git commit` / `git push` without approval. Normal
commits during a working session, where the user has already asked you to
implement something and the changes are obviously in scope, are fine — the rule
is about unsolicited or surprising changes, not every commit.

## `MUST_FAIL`

`MUST_FAIL` indicates a NEGATIVE TEST. It is NOT a marker for "a test that is
failing when it should not be."

## Metacircular compilation: four stages, not two

Koru's own compilation pipeline is written in Koru (`koru_std/compiler.kz`). A
single `koruc input.kz` invocation runs:

- **Stage A — `koruc` (Zig):** parses the input and emits `backend.zig` +
  `backend_output_emitted.zig` (the pipeline itself, compiled to Zig — including
  any user `~std.compiler:coordinate = ...` override).
- **Stage B — `zig build` backend:** compiles those into a `backend` binary.
- **Stage C — `backend` runs:** executes the metacircular pipeline
  (`context_create → frontend → analysis → test_generation → optimizer → emission`).
  `analysis` invokes `shape_checker.zig`, `flow_checker.zig`,
  `phantom_semantic_checker.zig` against the user's AST. Most semantic checking
  happens here. Emits `output_emitted.zig`.
- **Stage D — `zig build` output:** compiles the final user binary.

When hunting where a pass is invoked, grep `koru_std/` as well as `src/` —
passes are often wired in from Koru code, not Zig. `EXPECT` values map to
stages: `FRONTEND_COMPILE_ERROR` = A, `BACKEND_COMPILE_ERROR` = B,
`BACKEND_RUNTIME_ERROR` = C.

## Regression suite etiquette

The full suite takes 40+ minutes; the user runs it themselves. Use targeted
commands:

```bash
./run_regression.sh --status       # See current state
./run_regression.sh --regressions  # Find failing tests
./run_regression.sh --history 123  # Check specific test history
./run_regression.sh 330_016        # Run a single test
./run_regression.sh 330            # Run a range (330-339)
```

Unit tests are cheap and targeted:

```bash
zig build test                    # All unit tests
zig build test-phantom-checker    # Just phantom checker
zig build test-shape-checker      # Just shape checker
zig build test-auto-discharge     # Just auto-discharge
```

## The `~` prefix is parser mode, not a call operator

`~` switches the parser from Zig to Koru. It is NEVER used inside a Koru flow.
Once you're in Koru, you stay in Koru until the flow ends.

```koru
~get_user(id: 4)                   // ~ here: switching from Zig to Koru
| ok u |>
    get_permissions(user: u)       // NO ~ here: already in Koru flow
    | ok p |>
        std.io:print.ln("...")     // NO ~ here either
        | then |> ...
```

Writing `~` inside a flow silently creates two separate flows with unrelated
bindings. The parser accepts it; you get mysterious "unused binding" or
"undefined name" errors downstream.

## Phantom states are string-literal types

`[open]` and `[opened]` are completely different phantom types. They are
semantically related in English but the phantom checker compares strings, not
English. A branch that returns `*File[opened]` cannot satisfy a parameter
requiring `*File[open]`.

When chasing phantom-type bugs, check state literals for spelling / plurality /
tense mismatches first: `open` vs `opened`, `active` vs `activated`, `close`
vs `closed`, `connect` vs `connected`. This is independent of the `!`
obligation marker.

## Phantom states vs. obligations

Phantom state is the foundation: "what state is this value in?" The `!` marker
is a layered decoration:

- `*T[state!]` on a branch return = "produces an obligation on `state`"
- `*T[!state]` on a parameter = "discharges the obligation on `state`"
- `*T[state]` alone = plain state matching, no obligation machinery

State matching works without obligations. A unit-of-measure typing like
`f32[celsius]` is pure state matching — temperatures don't get cleaned up.

## Identity branches

Branches must carry meaningful payload. Two shapes:

- **Identity:** `| name *T[state]` — binds a single typed value. Captured with
  `| name x |>`, `x` IS the payload.
- **Struct:** `| name { a: A, b: B }` — multiple named fields (must be > 1).
  Captured with `| name x |>`, access fields as `x.a`, `x.b`.

Single-field struct payloads (`| name { x: T }`) are rejected by the parser at
the event declaration site — use identity instead. Branches with no payload
(`| done`) are also disallowed — if there's nothing meaningful to say, the event
should be void (no branches at all).

The parser does NOT reject single-field shapes at the branch *constructor* site
in flows — compile-time constructs can produce constructor-like AST nodes that
must be legal at parse time. The shape checker enforces validity there.

## Tests are the spec

We're rewriting the language so the test suite cannot pass unless it matches
the language design. That means tests are increasingly authoritative — when a
test disagrees with an intuition or a prose note, the test wins. Documentation
(including this file) is interim scaffolding; it will be generated from tests
once the spec crystallizes.
