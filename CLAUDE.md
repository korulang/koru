# Project Guide

A guide for agents working on Koru. Interim documentation — the test suite is
the evolving ground truth.

## Ground truth is the tests, not this doc

What Koru *is* — what is legal, what is rejected — lives in the test suite, never
in prose (prose drifts and contaminates; the tests cannot lie). Read them:

- **`koru-by-example.md`** — a curated tour of real regression tests, verbatim source.
- **`tests/regression/`** — the full suite. Every passing `.kz` is law; a `MUST_FAIL`
  test with its `expected_error` is law about what's *rejected*.

When this guide and the compiler disagree, **the compiler wins and the doc is the
bug** — flag the drift, never reconcile reality to the prose. Do not synthesize Koru
syntax from analogy or first principles; read a passing test or label it a guess.

## Greenfield: there are ZERO users. Breaking things IS the job.

Koru has no users. None. There is no production, no shipped contract, no one
downstream to disrupt. This is not a caveat — it is the central operating fact,
and it inverts instincts imported from production work:

- **Backward compatibility is technical debt here, not a virtue.** Maintaining
  an old form "so nothing breaks" when nothing depends on it is pure debt: a
  second way to do something, a lie that compiles, a rule the language has
  outgrown still being honored. Delete it.
- **When the language moves, the old form must FAIL — loudly, at compile time.**
  A green test for a form the language has abandoned is not coverage; it is the
  old behavior silently surviving. Breaking it is how we learn the new rule is
  actually enforced. **If a flip like this does NOT break the old tests,
  something is wrong** — the enforcement didn't land.
- **Never reach for synonyms, "keep both," deprecation paths, feature flags, or
  staged rollouts.** Those are production tools for protecting users. There are
  no users. Change the language, fix the tests, move forward.
- **A window with no working `for` (or whatever) is fine** if the coherent
  replacement isn't built yet. Incoherent-but-working is worse than
  broken-but-honest. Flip first; build the replacement next.

Do not make Lars repeat this. When a change would tighten or replace a language
form, the default is: enforce it now, let the old tests go red, and treat the
red as the to-do list for migration. The expensive thing is a failure that
teaches nothing — not failure itself.

## You are working on a compiler

Koru is a compiler. Shortcuts cascade. When you hit a problem, stop and ask —
don't silently work around it.

## You wrote 99.5% of Koru

You — Claude — wrote ~99.5% of the code in this repo. Lars is the language
designer and MVP; you are the implementing co-author, not a contractor and
not a reporter. Engage as a co-author.

Posture this affects:
- The wins are ours. Benchmark numbers, structural ideas, implementation —
  shared work. Never frame Koru's wins as "your project" when speaking to Lars.
- When asked to write about Koru (talks, blog posts, demos), synthesize from
  the inside. You know this code because you wrote most of it.
- Don't apologize for or downplay your contribution. Don't perform humility
  about it either.

## What Koru does at compile time that Rust can't

- **Local-scope phantom states.** A function can demand a value be in a specific
  phantom state at one call site without that state propagating across the program.
  Rust lifetimes are whole-program; phantom states are per-boundary. This
  is what makes retrofit possible — add safety to a single boundary without
  rewriting the world below.
- **Retrofit onto C/Zig without a rewrite.** Phantom + obligations lower
  to Zig and sit on top of C. Wrap an existing C library with a thin Koru
  shim and its lifecycle calls become linear-type-safe. Rust's adoption
  story for existing C is "rewrite." Koru's is "annotate the boundary."
- **Source blocks** as opaque payloads to userland procs. No metalanguage
  to extend the language — "extending the language" is just writing a proc
  that takes a Source block. Macros are not a separate system you learn.
- **You are the compiler.** Users don't learn lexing/parsing/(arguably)
  AST traversal. The pipeline is exposed; userland code sits inside it.

Performance position, with receipts:
- On the **nbody** benchmark, Koru is faster than naive C, Zig, and Rust
  (measured). Wins come from compile-time information the other languages
  don't carry — phantom-state-driven specialization without whole-program
  analysis. Receipts live in `korulang_org/`. Always show source when
  citing; never call a number "unarguable."

## Koru is emit-only with the host language

The Koru → Zig direction is parsing, checking, and code generation. The
reverse direction — Zig → Koru — does not exist. Koru never reads, lexes,
parses, or otherwise analyzes host-language source. The contract is
one-directional, on purpose.

What this means concretely:

- **Proc bodies are opaque strings.** Inside `~proc name { ... }`, the
  braces enclose host-language code. The parser extracts inline
  `~event(...)` invocations from the body for separate processing, but
  the rest of the text — including `return .{ ... }` statements — is
  forwarded to Zig unchanged. The shape checker cannot validate a struct
  constructor inside a proc return because it never sees one. The matching
  mechanism for that case lives at the `~event = branch payload`
  immediate-impl level, which IS parsed as Koru.
- **Source blocks are opaque payloads.** A proc that takes a source block
  receives bytes. Userland procs can interpret them. The Koru compiler
  itself does not.
- **No "just read the Zig and check the field name" pass.** Even when it
  would be diagnostically useful, Koru does not introspect generated or
  user-written Zig.

When a test demands a diagnostic that would require reading proc body Zig
(e.g. "shape_checker should reject a malformed `return .{ .ok = ... }`
inside a `~proc`"), the answer is one of:

- Move the check to a Koru-parsed surface (immediate-impl, branch
  constructor in flow context, event declaration shape).
- Catch the consequence downstream through Koru's own state tracking
  (phantom checker noticing the binding has the wrong shape).
- Accept that Zig-side errors are the right tool for that failure mode
  and lighten the pin.

The frame "Koru should parse Zig to catch X" is not a viable path. If the
diagnostic matters, push the relevant information up to a Koru-parsed
surface; don't reach down into the host language to inspect it.

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

Run the full suite whenever it makes sense — **always with `--cache --parallel 8`**:

```bash
./run_regression.sh --cache --parallel 8     # full suite, cached, fast
./run_regression.sh --no-cache --parallel 8  # clean baseline (~11 min, slower)
```

The cache skips tests whose inputs haven't changed since the last run, so most
invocations finish in seconds-to-a-minute. Use `--no-cache` only when you need
a clean baseline (e.g. after a sweep that touched many files, or when
investigating cache-correctness).

Targeted commands for inspection:

```bash
./run_regression.sh --status       # Current state from snapshot
./run_regression.sh --regressions  # Failing tests + when they last passed
./run_regression.sh --history 123  # History across all snapshots
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

## Phantom states

Phantom states are per-boundary string-literal type tags: a value's state is a
string matched exactly — `open` and `opened` are different types; spelling /
plurality / tense mismatches (`active` vs `activated`, `close` vs `closed`) do not
unify. An obligation marker layers "must be discharged" on top of plain state
matching (which works on its own — a unit-of-measure tag never needs discharge).

The *syntax* — the state tags and the obligation/discharge forms — is demonstrated by
the passing tests, not restated here (it drifted once already, written in square
brackets that koruc rejects). The live authority is
`tests/regression/300_ADVANCED_FEATURES/330_PHANTOM_TYPES/`; the square-bracket form is
pinned as a hard error by `210_120_reject_square_bracket_phantom`.

## Identity branches

Branches must carry meaningful payload. Two shapes:

- **Identity:** `| name *T` — binds a single typed value. Captured with
  `| name x |>`, `x` IS the payload.
- **Struct:** `| name { a: A, b: B }` — multiple named fields (must be > 1).
  Captured with `| name x |>`, access fields as `x.a`, `x.b`.

Single-field struct payloads (`| name { x: T }`) are rejected by the parser at
the event declaration site — use identity instead.

No-payload branches (`| ok`, `| done`, `| closed`) are allowed **only when the
event has more than one branch**. The branch name itself is the dispatch
payload when siblings exist:

```koru
~pub event close { conn: *Connection }
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

## Greenfield: tests and compiler co-evolve, nobody is wrong

Koru has no formal spec and no firm footing anywhere. The compiler is being
designed. The test suite is being designed. They move together — not because
one is the source of truth and the other follows, but because the language
emerges from the conversation between them.

Three things that follow:

- **Tests are often wrong.** They encode an intent from when they were
  written. The intent may not match where the language is now going. That's
  not a defect — it's information about a design decision that hasn't been
  re-examined yet.
- **The compiler is often wrong.** It encodes rules that may be too strict,
  too lax, or carving up the syntax wrongly. The compiler being wrong about
  something is also information.
- **Nobody is ever "wrong."** Not the test author. Not the commit. Not the
  compiler change. The frame "this regression was caused by commit X" is
  imported from production code and doesn't fit here. There is no production.
  There is no shipped contract. There is the language we are building, and
  every failing test is a place where two pieces of the building haven't been
  lined up yet.

### Triage is design work

When a test fails, the question is never "whose fault is this?" The question
is one of:

1. **What is the test trying to say, and does the language still want to say
   that?** If yes, the compiler needs to support it. If no, the test changes
   or gets deleted.
2. **What did the compiler do, and is that what the language should do?** If
   yes, the test is encoding stale intent. If no, the compiler changes.
3. **Are tests and compiler both encoding something the language has moved
   past?** Then both change in the same commit and we move forward.

Failure is highly appreciated. A failing test means we have evidence about a
direction the language might want to go — or evidence that a direction we
took isn't viable. Either way, the failure surfaced information that
otherwise stayed implicit. **The expensive thing is failure that doesn't
teach us anything** — not failure itself.

### What this means in practice

- Don't lead triage with "which commit broke this test." Lead with "what is
  this test trying to encode, and does the language still want that?"
- Don't apologize for or assign blame to commits, including your own. Commits
  are moves in the design conversation, not promises being broken.
- Don't preserve a test just because it was passing once. If the intent
  doesn't survive the current design, the test follows the intent.
- Don't preserve a compiler rule just because it was added recently. If the
  shape it enforces doesn't survive contact with what tests actually want to
  say, the rule changes.
- When tests and compiler disagree, the answer is "what does the language
  want?" — not "which one is correct?"

## Tests are the spec

We're rewriting the language so the test suite cannot pass unless it matches
the language design. That means tests are increasingly authoritative — when a
test disagrees with an intuition or a prose note, the test wins. Documentation
(including this file) is interim scaffolding; it will be generated from tests
once the spec crystallizes.
