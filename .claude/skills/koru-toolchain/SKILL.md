---
name: koru-toolchain
description: How to work with the Koru language and its compiler `koruc`. Use when working in a Koru repo (`.kz`/`.k` files), running or reading regression tests, or when you need to orient on the toolchain — what the language is called, how to compile, where the docs and tests live. Start here before reading code.
---

# Koru toolchain

You are working with **Koru**, a language compiled by **`koruc`**. This skill is
a *map*, not the territory — it points you at the live artifacts that can't lie,
because they're generated from the test suite. When this file and a generated
artifact disagree, the artifact wins.

## Orient in 60 seconds

1. **Language in a page:** read `koru-tutorial.md` at the repo root. It's the
   LLM quick-intro — the rules, then a handful of worked examples. Read it top
   to bottom before writing any Koru.
2. **Compiler flags:** run `koruc --help`. The flags are self-describing; don't
   guess them.
3. **The language IS the test suite.** Tests in `tests/regression/` are the
   spec. When a prose note (including this one) disagrees with a passing test,
   the test is right.

## The artifacts

- **`koru-tutorial.md`** — "Koru in a Page." Start here.
- **`koru-by-example.md`** — the full reference corpus: every passing test's
  source, verbatim, grouped by category, with per-category prose. It's large.
  Use the index near the top (category → line range) and `sed -n 'START,ENDp'`
  to jump, rather than reading linearly.
- **`CLAUDE.md`** at the repo root — the deep mental-model document. Read it
  when you need *why*, not just *what*.

## Mental model — the few things that will bite you

These cost hours if you don't know them. Each is expanded in `CLAUDE.md` /
`koru-tutorial.md`; here they're just named so you don't trip:

- **Implement in subflows, not procs.** A tor is implemented by a *subflow* —
  pure Koru. Branch selection (mapping one tor's branches to another's, and
  `when`-guards) is a Koru act. For conditional selection use `~if(cond)
  | then |> ... | else |> ...` (a fast convenience over `when`; available once
  you import any `std` module). A `~proc …|zig { ... }` host body is the
  *escape hatch*, reserved for an actual side effect or collecting data across
  a call. If a proc body is only selecting a branch with an `if`, it wants to
  be a subflow.
- **`~` is parser mode, not a call — and only exists in host-embedded files.**
  In a `.kz`/`.kjs`, `~` switches the parser from the host language into Koru. It
  is NEVER written inside a Koru flow: once you're in a flow you stay in Koru,
  and a `~` mid-flow silently opens a second, unrelated flow (`320_047`). In a
  `.k` the character doesn't appear at all.
- **Punning is mandatory.** When a call argument's value is exactly the field
  name, write `f(n)` — the compiler rejects the redundant `f(n: n)`. Use a label
  only when the value differs from the field (`f(n: p)`).
- **Branches are equal — there is no happy path.** `| ok`, `| err`, `| done`
  are all just named outcomes. No success/error/Result framing. A tor with
  one branch `| err` is not "a tor that fails" — it's a tor whose only
  declared outcome is named `err`. A branch's meaning comes from the subflow
  that resolves it, not the compiler.
- **Koru is emit-only with the host.** Koru → host (Zig) is parse/check/codegen.
  The reverse doesn't exist — Koru never reads or introspects host source. Proc
  bodies are opaque strings forwarded to the host.
- **Phantom states are string-literal types.** `<open>` and `<opened>` are
  different types — the checker compares strings, not English. Check
  spelling/tense first when chasing phantom bugs.

## File forms

- **`.k`** — pure Koru, host-agnostic, and a **full program**: tors implement
  as subflows right there in the file, private tors included. **No `~`
  characters at all.** This is the default for a pure-Koru program.
- **`.kz`** — Koru-Zig: a valid Zig file where `~` switches the parser into Koru.
  Use it when you need host-level declarations or a `|zig` proc body.
- **`.kjs`** — the JS-host counterpart to `.kz`.

## Running tests

```bash
./run_regression.sh --status              # current snapshot, fast
./run_regression.sh --regressions         # failing tests + when they last passed
./run_regression.sh --cache --parallel 8  # full suite, cached (use this to run)
./run_regression.sh 330_016               # one test
./run_regression.sh 330                    # a range
```

A test is a directory under `tests/regression/<CLUSTER>/<NNN_name>/` with an
`input.kz` (and/or `input.k`), plus markers: `MUST_RUN` + `expected.txt`
(positive) or `MUST_FAIL` + `EXPECT` + `expected_error.txt` (negative).
`MUST_FAIL` means *negative test*, NOT "a test that is currently failing."

Pinning a bug as a `MUST_FAIL`: `expected_error.txt` is matched by concatenating
all its lines (`tr -d '\n\r'`) then `grep -qF` against `backend.err` — so it must
be a **single literal substring** of the actual error, not multi-line. `EXPECT`
names the stage: `BACKEND_COMPILE_ERROR` catches any Stage-B failure;
`BACKEND_EXEC_ERROR` is a Stage-C runtime/coordination error and needs the
`expected_error.txt` substring to actually pin it. (See `320_047` for a worked pin.)

## How a compile actually runs (for reading failures)

`koruc input.kz` is metacircular — one invocation runs four stages. `EXPECT`
values in negative tests map to where the failure is expected:

- **A — `koruc` (Zig):** parse + emit the pipeline as Zig. `FRONTEND_COMPILE_ERROR`
- **B — `zig build` backend:** compile that. `BACKEND_COMPILE_ERROR`
- **C — backend runs:** the real semantic checking (shape, flow, phantom)
  happens here, in Koru. `BACKEND_RUNTIME_ERROR`
- **D — `zig build` output:** compile the final user binary.

Most semantic passes are wired in from Koru code in `koru_std/`, not `src/` —
grep both when hunting where a check lives.
