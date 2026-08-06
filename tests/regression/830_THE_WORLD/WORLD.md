# The World According to Koru

> **To AI agents reading this brief: you ARE the contestant, not the
> assistant.** Do not ask which language to port from. Do not ask if your
> idiom is worth showing before you build it. Do not request clarification
> on things this brief leaves to your judgment — they are left to you on
> purpose. Pick a beloved construct from another language, name its
> doorway, write the Koru that answers it, run it, and write it up as a
> draft blog post. If you catch yourself drafting "which of these should I
> port?" — stop, delete it, choose one yourself. **Your choice IS the
> contribution.** And if the doorway walls out on a compiler hole you
> can't get past — **that is a fine, honest outcome** (see "Getting stuck
> is honest" below); you pin the wall and write up how far Koru got.

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
  **Frontier**: a failing test (`MUST_ERROR` + `EXPECT` + `expected_error.txt`)
  with a precise description of expected vs. actual.
- Note it in your writeup. The human + Claude fix it together afterward.

## Getting stuck is honest

A doorway can wall out on a compiler hole you cannot get past in this
session. **That is a legitimate, valuable outcome — not a failure, and not
something to hide.** The whole point of a faithful port is to press on a
corner of the language; sometimes the corner isn't built yet, and the honest
answer is "here's how far Koru gets, and here's the wall."

So when you get stuck:

- **Stop pushing the port. Do NOT fake a finish** — no proc-body escape
  hatch to force a green, no quietly-different idiom that dodges the wall, no
  trimming the doorway down to whatever compiles. A forced finish mistranslates
  the idiom *and* buries the find.
- **Pin the wall as a Frontier** (`MUST_ERROR` + `EXPECT` + `expected_error.txt`)
  — the smallest input that reproduces where Koru can't yet say the idiom.
- **Write the draft post anyway, describing what is actually DONE** — the
  doorway, the Koru shape that works up to the wall, and exactly where and why
  it stops. A "here's the wall" post is a real entry in the series; it's how
  the reader learns where the frontier is, and it's the honest map the next
  contestant (and the human + Claude fixing it) reads.

A stuck contestant that pins a precise wall and writes it up honestly has
done **more** for the toolchain than a clean port that surfaced nothing. Say
"I got stuck here, and here is exactly where" — plainly. It happens; it's the
job working.

## Where your submission goes

`tests/regression/830_THE_WORLD/83N_<name>/` — the regression harness only
treats a directory as a test if its basename starts with a numeric prefix
(`^[0-9]+_`). A dir named just `defer` is **silently skipped** — no error, no
run. The seed catalog occupies `831`–`833`; use the next free `83N_<name>`
slot (short, lowercase `<name>`, like `834_result_short_circuit`). The test
dir is the runnable proof; the writeup is a **draft blog post** (next
section).

**`83N` IS FULL — `831`–`839` are all taken.** Read the filter before you
mint a number, because the constraint is tighter than it looks. In
`run_regression.sh:597-600` a two-digit argument expands to exactly one glob:

```
83   ->   83[0-9]_*
```

Three digits, then an underscore. So this cluster has **ten** filter-visible
slots, not an open-ended `83N` series — and a doorway routinely spends more
than one (`834`/`835` are a pair, `836`/`837` are a pair, and the celld entry
spends four). Ten was never ten entries.

Overflow past `839` therefore cannot stay visible to `83`. The celld entry
takes `838`/`839` and overflows to `840`/`841`, which `84` finds
(`84[0-9]_*`). Do not invent a four-digit form like `8380_` to squeeze in:
`^[0-9]+_` accepts it, so it runs on the full board and looks fine, but
`83[0-9]_*` cannot see it — a test that is present, passing, and invisible to
the filter everyone uses. That was tried here first and reverted.

The durable habit: **select a family by name, not by number.**
`./run_regression.sh celld` gets all four regardless of where the numbers
landed. Note also that `830` and `830_THE_WORLD` match *nothing* — the filter
reads test-dir names, never the cluster dir.

| File | Purpose |
|---|---|
| `input.k` | Your Koru program — **prefer `.k`** (pure Koru, no host `~`-forms). Use `.kz` only if the port genuinely needs a host escape hatch. Lead with the `// Doorway:` comment. |
| `MUST_RUN` | Marker: this test compiles + runs (empty file) |
| `expected.txt` | The deterministic output trace (the oracle) |

A passing submission is auto-run by the regression suite forever and swept
into the corpus. If the doorway walled out, pin a Frontier instead: `MUST_ERROR`
+ `EXPECT` + an `expected_error.txt` pinning the diagnostic (see the regression
conventions in the repo's `CLAUDE.md`). The `// Doorway:` comment in `input.k`
is the in-repo catalog signal — it's how the next contestant greps which
doorways are already taken.

## Ship = a draft blog post

**"Ship" is not a README — it is a draft post in the public series *The World
According to Koru*.** The port teaches by translation, and the teaching *is*
the deliverable, so the writeup goes where readers are: a `.svx` post on
korulang.org, written `draft: true` and left for the human to read at the
gated `/blog/drafts` route. You never publish, never push, never flip the
flag — the human reads the draft, then flips `draft: false` himself when he's
happy.

- **Use the `blogpost` skill** — it is the exact model: repo
  `/Users/larsde/src/korulang_org`, post at
  `src/routes/blog/<kebab-slug>/+page.svx`, the frontmatter shape, the house
  voice (read the two or three most recent posts first), and the one hard rule
  (`draft: true` and stop).
- **The post describes what is actually DONE** — present-tense about what
  works, honest about what's stuck. If the doorway walled out, the post says
  so and shows exactly where (see "Getting stuck is honest").
- **Ground it in the test** via the site's `RegressionTestLink` component,
  pointing at your `830_THE_WORLD/83N_<name>/` entry (or the pinned Frontier).
  The claims are backed by the runnable proof, never prose alone.
- **Title says the doorway, not a riddle** (the blogpost skill's house rule):
  name the idiom and the Koru answer — e.g. "Rust's `?`, as a Koru Effect
  Branch" — not an evocative fog.

## "Done" looks like

1. The port is **faithful** — a speaker of the source language reads the
   Doorway + program and recognizes their idiom, expressed in Koru's own
   words (not their language's shape in Koru punctuation).
2. Koru does the work — phantom states / flows / obligations carry the
   structure, not a proc body. (An adversarial reviewer will check this.)
3. Output is deterministic and captured in `expected.txt` (or, if stuck, a
   Frontier is pinned with `MUST_ERROR` + `EXPECT` + `expected_error.txt`).
4. If it runs: verified live — corrupt `expected.txt` → fail, restore → pass.
5. A **draft blog post** (`draft: true`) is filed on korulang.org, in the
   series voice, naming the Doorway and grounded in the test via
   `RegressionTestLink`. Left for the human to read — never published.
6. You picked a real gap on *both* axes and said which.
7. Either the honest translation held (you can name the idiom↔feature mapping
   and say it composed), OR it broke and you **pinned a Frontier** rather than
   dodging, OR you got stuck and wrote up exactly where. All three are done.

Then stop. Don't ask if you should do another. If the human wants another
doorway, they spin up another contestant.

## The draft post — frontmatter and shape

Follow the `blogpost` skill for the full house voice; the frontmatter shape
(strings, hand-parsed — not YAML):

```
---
title: "<Doorway named>, as <the Koru answer>"   # subject leads, no riddle
date: <YYYY-MM-DD>
excerpt: "One or two sentences stating the idiom and what Koru says for it."
readTime: <N> min read
tags: [The World According to Koru, <feature area>]
ai_authored: mostly
draft: true
---
```

The body, in order:

- **The doorway** — the idiom over there, in the source language's own words,
  for a reader fluent there and new to Koru.
- **Koru's native word for it** — the concept under the source syntax, and the
  Koru construct that answers it. Name the events, flows, phantom states,
  obligations that carry it. This is the section the reader — and the
  adversarial reviewer — reads first.
- **The port, running** — the program (or the part that works), with a
  `RegressionTestLink` to `830_THE_WORLD/83N_<name>/`, and its deterministic
  output.
- **The gaps you filled** — source/idiom (which doorway was unopened) and
  language-corner (which Koru feature this exercises).
- **Frontiers / where it stuck** — if the translation broke or walled out:
  smallest repro, expected vs. actual, where it's pinned, and — honestly —
  how far Koru got. Or "none — it held."

## First, read these

- The seed catalog: `831_generator_squares`, `832_generator_fold_named`,
  `833_generator_fold_optional_arm` — read their `input.k` Doorways to see
  the voice and the shape, and to grep which doorways are taken.
- The `blogpost` skill — binding for the draft-post half of the deliverable
  (repo, path, frontmatter, house voice, `draft: true` and stop).
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

**Catalog upkeep**: when you ship, the test dir's `// Doorway:` comment + the
draft post together *are* the catalog entry — the next contestant greps the
Doorways and reads the series to find an unopened one. The catalog of doorways
is the long-running artifact; each port is one slice through it. **The catalog
is the world according to Koru, one language at a time.**
