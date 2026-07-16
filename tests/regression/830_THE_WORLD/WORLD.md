# The World According to Koru

> **To AI agents reading this brief: you ARE the contestant, not the
> assistant.** Do not ask which language to port from. Do not ask if your
> idiom is worth showing before you build it. Do not request clarification
> on things this brief leaves to your judgment — they are left to you on
> purpose. Pick a beloved construct from another language, name its
> doorway, write the Koru that answers it, run it. If you catch yourself
> drafting "which of these should I port?" — stop, delete it, choose one
> yourself. **Your choice IS the contribution.**

Take one construct that people *love* in another language — the thing a
Rubyist reaches for, the reason a Haskeller smiles, the Go idiom on every
cheat sheet — and show how the same idea is expressed **idiomatically in
Koru**. Not transliterated glyph-for-glyph: *translated in spirit*, the way
a native speaker would say it. The deliverable is a small, beautiful,
deterministic program that a reader who knows the *other* language can look
at and go "oh — *that's* how Koru does it."

This is a sibling of the Koru Challenge (`../800_CHALLENGES/CHALLENGE.md`),
not a copy. There, the axis is *invent a program that stresses the
toolchain and pin what breaks.* Here the axis is **fidelity**: faithfully
re-express a known idiom so the translation itself teaches. The
Frontier-hunting discipline still rides along — when the honest translation
bends the compiler, you pin it — but the primary artifact is the *port*,
and the primary metric is **how many different doorways the catalog opens.**

## The Doorway is mandatory

Every entry opens with a `// Doorway:` comment naming the source language and
the exact construct, so the reader arrives holding the thing they already
know. From the seed catalog:

```
// The World in Koru — generators, entry 1.
// Doorway: Python's `def squares(n): for i in range(n): yield i*i`.
// Here in Koru: `squares` is an effect-bearing event whose subflow FIRES
// `! each` per element — a generator whose control flow is the type.
```

The Doorway is the whole pedagogical move: *you knew this over there; here it
is over here.* No Doorway, no entry.

## The two non-negotiables

1. **Koru has to actually do the work.** The logic lives in **events,
   flows, phantom states, and obligations** — not stuffed inside one opaque
   `~proc|zig { ... }` body. A proc body is host code the compiler can't
   see; a port that hides the idiom inside one is a Zig program in a Koru
   hat and it doesn't count. Procs are the *leaves* (a print, a primitive);
   the *structure* is Koru. If your program would work identically with the
   phantom states and flows deleted, you have not shown Koru's answer — you
   have shown Zig's.
2. **Deterministic output.** The program prints a trace the same run
   reproduces every time. That trace, captured in `expected.txt`, is the
   oracle. No clocks, no randomness, no wall-time — fixed input, fixed
   output.

## Fidelity, not transliteration

The failure mode here is subtle and it is the opposite of the 800 dodge.
There, contestants *retreat* from the natural shape to stay green. Here the
temptation is to **force the other language's shape onto Koru** — to write
Python-with-Koru-punctuation and call it a port. That is a mistranslation,
and it teaches the reader the wrong thing.

- **Translate the *idea*, then find Koru's native word for it.** Python's
  generator is not "a function that yields" — it is *lazy per-element
  production*, and Koru's native word for that is an effect-bearing event
  whose subflow fires `! each`. Rust's `?` is not "a question mark" — it is
  *short-circuit on the error arm*, and Koru has effect branches. Find the
  *concept* under the syntax, then ask what Koru already says for it.
- **If Koru genuinely has no native word yet, that is a Frontier**, not a
  license to fake one. Pin it (below). A missing idiom is data about the
  language, and it is worth more than a forced imitation that compiles.
- **The reader is a speaker of the OTHER language.** Write the Doorway and
  the README for someone fluent over there and new here. The port is good
  when *they* nod.

## Variance is the metric

Replays are only productive if they *differ*. Before you build, read the
catalog and bring a doorway it does not already have — across **two axes**:

1. **Source-language / idiom gap.** `ls` the existing entries and read their
   Doorways. The seed catalog is generators (`831`–`833`, all Python's
   `yield`/`sum(gen)`). So do **not** ship a fourth generator port — reach
   for a different language and a different organ of it: Rust's `?` and
   `Result`, Go's `defer` / channels / `select`, Haskell's `foldr` / Maybe
   / list comprehension, Erlang's supervision-and-restart, Ruby's blocks,
   SQL's `GROUP BY`, a Lisp fold, C's `goto`-cleanup ladder (Koru's
   obligation answer!), Elm's update loop, a Smalltalk cascade.
2. **Language-corner gap.** Which *Koru* feature does your port exercise
   that the catalog under-uses? Generators lean on `! each` + subflows and
   consumer-side `capture`. A `defer`/cleanup port would lean on
   **obligations**; a `Result`/`?` port on **effect branches**; a state
   machine on **phantom states**. Pick a port that lights up a corner the
   catalog leaves dark, and say which one.

The existing entries ARE the backlog. There is no TODO list — the catalog is
the spec for what's missing.

## Write the natural shape — then pin what breaks

Same discipline as the Koru Challenge, because a faithful port is exactly
the pressure that finds holes. Write the port the way you'd write it if the
toolchain were already perfect — the most direct idiomatic Koru for the
idea. Do NOT pre-defend against bugs you suspect; do NOT retreat into a proc
body to sidestep a wall. When the honest translation breaks, *that break is
the data* — it means the idiom you're porting touches a corner Koru can't
yet say cleanly.

The seed catalog already shows this: `832` and `833` were pinned RED first
(folding a named generator consumer-side leaked raw Zig instead of a Koru
diagnostic), then driven green. That pin-then-fix is the loop.

So when the compiler rejects something it shouldn't, emits broken code, or
crashes:

- **Do NOT work around it silently. Do NOT contort the port to dodge it. Do
  NOT stuff the broken part into a proc body.** The dodge hides a hole we
  needed *and* mistranslates the idiom.
- **Pin it.** Reduce to the smallest input that reproduces, and leave a
  **Frontier**: a failing test (`MUST_FAIL` + `EXPECT` + `expected_error.txt`)
  with a precise description of expected vs. actual.
- Note it in your writeup. The human + Claude fix it together afterward.

## Where your submission goes

`tests/regression/830_THE_WORLD/83N_<name>/` — the regression harness only
treats a directory as a test if its basename starts with a numeric prefix
(`^[0-9]+_`). A dir named just `defer` is **silently skipped** — no error, no
run. The seed catalog occupies `831`–`833`; use the next free `83N_<name>`
slot (short, lowercase `<name>`, like `834_result_short_circuit`).
Self-contained:

| File | Purpose |
|---|---|
| `input.k` | Your Koru program — **prefer `.k`** (pure Koru, no host `~`-forms). Use `.kz` only if the port genuinely needs a host escape hatch. |
| `MUST_RUN` | Marker: this test compiles + runs (empty file) |
| `expected.txt` | The deterministic output trace (the oracle) |
| `README.md` | The writeup (template below) — part of "done" |

A passing submission is auto-run by the regression suite forever and swept
into the corpus. For a Frontier, use `MUST_FAIL` + `EXPECT` + an
`expected_error.txt` pinning the diagnostic instead (see the regression
conventions in the repo's `CLAUDE.md`).

## "Done" looks like

1. The port is **faithful** — a speaker of the source language reads the
   Doorway + program and recognizes their idiom, expressed in Koru's own
   words (not their language's shape in Koru punctuation).
2. Koru does the work — phantom states / flows / obligations carry the
   structure, not a proc body. (An adversarial reviewer will check this.)
3. Output is deterministic and captured in `expected.txt`.
4. Verified live: corrupt `expected.txt` → fail, restore → pass.
5. Writeup filed at `<name>/README.md`, including the Doorway.
6. You picked a real gap on *both* axes and said which.
7. If the honest translation broke something, you **pinned a Frontier**
   rather than dodging — or, if it held, you can name the idiom↔feature
   mapping you stressed and honestly say it composed.

Then stop. Don't ask if you should do another. If the human wants another
doorway, they spin up another contestant.

## Submission writeup template

```markdown
# <name>

**One-line pitch**: <the idiom, ported, in ≤20 words>

**Doorway**: <source language> — `<the exact construct, verbatim>`

## What it is
<3–6 sentences: the idiom over there, and what Koru says for it over here.>

## Koru's native word for it
<The concept under the source syntax, and the Koru construct that answers
it. Name the events, flows, phantom states, obligations that carry it. This
is the section the reviewer — and the reader — reads first.>

## Gaps I filled
- **Source/idiom**: <what doorway wasn't in the catalog before this>
- **Language corner**: <which Koru feature this port exercises>

## Frontiers hit (toolchain bugs)
<Each: smallest repro, expected vs. actual, where it's pinned. Or "none —
held; the mapping I stressed was <idiom> ↔ <feature>".>

## Output
<One-line description of the trace in expected.txt.>
```

## First, read these

- The seed catalog: `831_generator_squares`, `832_generator_fold_named`,
  `833_generator_fold_optional_arm` — read their `input.k` Doorways to see
  the voice and the shape.
- Its sibling brief: `../800_CHALLENGES/CHALLENGE.md` — the toolchain-hardening
  axis, shared discipline.
- Repo standards: `CLAUDE.md` + `AGENTS.md` at the repo root — binding.
  Especially "branches are equal," the `|>` layout rules, and phantom
  syntax (`<state>`, not `[state]`).
- `koru-by-example.md` — the canonical syntax oracle. Every shape you write
  should match something here. If you can't find a passing example of a
  shape your port needs, that's a red flag — pin it, don't invent it.
- Run a single submission: `./run_regression.sh <name>`.

---

**Catalog upkeep**: when you ship, the submission dir + its README *is* the
catalog entry — the next contestant reads it to find an unopened doorway.
The catalog of doorways is the long-running artifact; each port is one slice
through it. **The catalog is the world according to Koru, one language at a
time.**
