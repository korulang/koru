# Project Guide

A guide for agents working on Koru. Interim documentation — the test suite is
the evolving ground truth.

## You are working on a compiler

Koru is a compiler. Shortcuts cascade. When you hit a problem, stop and ask —
don't silently work around it.

## Branches are equal — there is no happy path

Every branch on an event is just an outcome shape with a name. They are equal
in every conceivable way. There is no privileged "success," no implicit "ok,"
no fallback "happy path," no "sad path." `| err`, `| ok`, `| done`, `| closed`,
`| timeout` — all the same kind of thing. Just named outcomes.

Do not import vocabulary or assumptions from other languages:

- No "happy path" / "sad path" / "error path."
- No "the success case is implicit."
- No "auto-inject an `ok` branch."
- No reasoning by analogy to `Result<T, E>`, `Either`, exceptions, or
  `try`/`catch`. That whole frame says "one outcome is the real one and the
  others are deviations." Koru does not work that way.
- No "the proc returns the value, and errors are the other thing." The proc
  emits one of its declared branches. That's the whole model.

What this means in practice:

- An event with one branch `| err` is **not** "an event that fails." It is an
  event whose only declared outcome is named `err`. If the proc body never
  emits that outcome, the source is incoherent — the proc declared an outcome
  it never produces.
- An event with no branches (void) is an event with no outcome shape, full stop.
  Not "an event that always succeeds."
- When a test or piece of code looks malformed, ask "which named outcome is
  this proc supposed to produce?" — not "what's the success case?"

If you catch yourself reaching for happy/sad/success/error vocabulary while
reasoning about Koru, stop. Restate in terms of named outcomes. The vocabulary
isn't decoration; using the wrong words means you're modeling the wrong
language.

### Stdlib conventions are not language semantics

The standard library converges on certain branch names by convention — `| ok`
and `| err` for events that can fail, `| done` for void terminators, `| then`
for continuations, etc. Readers of stdlib-shaped code will (correctly) bring
expectations to those names.

That convention lives **in the library**, not in the language. The compiler
does not privilege `| ok` over `| err` over `| anything_else`. A user defining
their own event can name branches `| north`, `| south`, `| sideways` and the
core machinery treats them identically. When you see `| ok` and `| err` in a
test, the meaning comes from stdlib usage, not from a language rule. Do not
extrapolate from "the stdlib uses `ok` this way" to "the language treats `ok`
specially." It doesn't.

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

## Layout: `|>` inline by default, multi-line only for void chains

Two rules govern how flows are laid out across lines.

### Rule 1: `|>` is ALWAYS inline. It never starts a line.

`|>` is the body delimiter of a branch handler (`| name [binding] |> body`)
and the chain operator between void events (`~A() |> B()`). It always stays
on the same line as what precedes it. A line that begins with `|>` (after
whitespace) is malformed, in **every** context — including void chains.

There is no "void chains may stair-step across lines" carve-out. If a chain
gets too long for one line, the fix is to refactor — either keep it inline
regardless of length, or write the steps as separate top-level statements
(which is already legal for top-level void events):

```koru
// Allowed: inline chain
~A() |> B() |> C() |> D()

// Allowed: separate top-level statements
~A()
~B()
~C()
~D()

// FORBIDDEN: |> at line start
~A()
|> B()       // ❌ malformed
|> C()       // ❌ malformed
```

The reflex to break on `|>` is borrowed from F#/Elm/Elixir, where it's
idiomatic. In Koru it is wrong. `|>` does not start lines.

### Rule 2: Branched chains stay inline; branches go DOWN

When the chain ends in (or contains) a branched event, the chain stays on one
line, and the branches go on subsequent lines. Branch indent is determined
by branch-handler nesting depth (see "Indent depth" below) — NOT by the
column where the dispatch point lands mid-line.

Canonical shape (from `030_011_array_literal_bindings`):

```koru
~getValue(id: 1)
| got a |> getValue(id: 2)
    | got b |> getValue(id: 3)
        | got c |> sumAll(values: [a, b, c])
            | total t |> check(expected: 60, actual: t)
```

Each `| name binding |> body` line:
- starts with `|` (branch dispatch)
- has its body inline after `|>`
- nests its own branches DOWN under the body's call column

Branches are NEVER on the same line as the chain whose result they dispatch
on. They always come down.

### Indent depth: branch-handler nesting only

Branch indent is determined **purely by branch-handler nesting depth**. Void
chains in front of a branched event are transparent for indent purposes — they
do not shift anything.

```koru
~getVoid() |> someBranchedEvent()
| ok x |> ...                       // col 0, same as if the line were
| err e |> ...                      // just `~someBranchedEvent()` alone
```

The branches sit where they'd sit if the void chain weren't there. They do
NOT indent under the column of `someBranchedEvent` mid-line. That position
was never a candidate.

Same principle nested:

```koru
| ok x |> doVoid() |> doBranched()
    | b_ok y |> ...                 // +1 from `| ok x`, same as if body
    | b_err e |> ...                // were just `doBranched()` alone
```

Each branch nesting step = +1 indent. Chain length never adds levels.

### What this rules out

- A `|>` line at deeper indent under a branch handler's body, with sibling
  `|` handlers at the same indent — the malformed shape from `330_012`.
- Trailing `|> _` on a new line — should be inline with the body.
- Branches on the same line as the chain that produced them
  (`~A() |> B() | ok x |> ...`) — branches always come down.
- Mixed-indent void chains (`|> step` at one indent, then `    |> step` at
  another) — flat or nothing.

### When in doubt, read passing tests

Read `tests/regression/` to see real Koru. Do NOT synthesize Koru syntax from
analogies to other languages or from first-principles guesses about what
"should" be valid. The language is what the code is, not what you reason it
might be. If you produce a syntax example that you have not seen in a passing
test, label it as a guess.

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
the event declaration site — use identity instead.

No-payload branches (`| ok`, `| done`, `| closed`) are allowed **only when the
event has more than one branch**. The branch name itself is the dispatch
payload when siblings exist:

```koru
~pub event close { conn: *Connection[!active] }
| ok                    // closed cleanly, nothing to carry
| err []const u8        // sibling makes `| ok` meaningful as a dispatch
```

What's NOT allowed: an event with a **single** no-payload branch.

```koru
~pub event ping { }
| done                  // ❌ no information — should be a void event instead
```

If the event has nothing to say beyond "it happened," declare it as void (no
branches at all). The single-no-payload-branch shape is just void with extra
ceremony.

The parser does NOT reject single-field shapes at the branch *constructor* site
in flows — compile-time constructs can produce constructor-like AST nodes that
must be legal at parse time. The shape checker enforces validity there.

## Tests are the spec

We're rewriting the language so the test suite cannot pass unless it matches
the language design. That means tests are increasingly authoritative — when a
test disagrees with an intuition or a prose note, the test wins. Documentation
(including this file) is interim scaffolding; it will be generated from tests
once the spec crystallizes.
