# The Koru Challenge

> **To AI agents reading this brief: you ARE the contestant, not the
> assistant.** Do not ask which direction to pick. Do not ask if your idea
> is good enough before you build it. Do not request clarification on
> things this brief leaves to your judgment — they are left to you on
> purpose. Pick a direction, name it, write Koru, run it. If you catch
> yourself drafting "which of these should I build?" — stop, delete it,
> choose one yourself. **Your choice IS the contribution.**

Build a non-trivial Koru program that makes the language *do the work*.
The point is not to ship something green. The point is to **probe the
toolchain at scale** — to write real Koru and find where it bends or
breaks. A program that compiles, runs, and reads beautifully is a win.
A program that hits a compiler wall you can pin precisely is *also* a
win — sometimes a bigger one. Both go in the catalog.

We have a suite full of naive tests. What we lack is *scale* — programs
where events, flows, phantom states, and obligations interact the way
they would in something a person would actually write. This challenge
fills that gap, one submission at a time.

## The two non-negotiables

1. **Koru has to actually do the work.** The logic lives in **events,
   flows, phantom states, and obligations** — not stuffed inside one
   opaque `~proc|zig { ... }` body. A proc body is host code the compiler
   can't see; if your whole solution sits in one, you've written Zig in a
   Koru hat and it doesn't count. Procs are the *leaves* (a single side
   effect, a print, a primitive); the *structure* is Koru. If your
   program would work identically with the phantom states and flows
   deleted, it doesn't count.
2. **Deterministic output.** The program prints a trace that the same run
   reproduces every time. That trace, captured in `expected.txt`, is the
   oracle. No clocks, no randomness, no wall-time — a fixed input
   produces a fixed output.

## Two tiers — pick where your energy is

This is a difficulty gradient, not a ladder you must climb. Both tiers
are valuable; the on-ramp is not "lesser."

### Tier 1 — Tutorial (the on-ramp)
Build something a newcomer would *want to read* to learn Koru. Small,
complete, charming. The catalog of ideas is a starting kit, not a menu:

- **A To-Do list** — add / complete / remove items; item state
  (`pending` → `done`) as phantom states; iterate to display.
- **A small game** — guess-the-number, tic-tac-toe, a turn counter, a
  tiny text adventure as a state machine.
- **A calculator** — a stack machine, or expression evaluation over a
  fixed input.
- **A simulation** — a traffic light, a vending machine, an elevator with
  a few floors.

A passing Tier-1 submission flows into `koru-by-example.md` and
`koru-tutorial.md` — it literally becomes how the next reader (human or
AI) learns the language. The writeup matters.

### Tier 2 — Resource lifecycle / protocol (the deep end)
Model something whose *correctness is a lifecycle*. This is where Koru's
headline — phantom states + obligations — earns its keep:

- A connection pool; a transaction with commit / rollback; a file-handle
  manager; a lock / semaphore; a session with login → active → expired.
- A protocol state machine: a handshake, a retry loop, a multi-stage
  request pipeline across modules.

Here the non-negotiables bite hardest: the resource's **states must be
phantom types**, and the **cleanup contract must be an obligation** the
type system enforces. If you can delete the `<state>` annotations and the
`!` markers and it still compiles, you haven't used the language.

## Self-organize — fill a gap, across both axes

Before you build, look at what's already here and bring something
*different*. Variance is the metric. Two axes to scan:

1. **Domain gap** — `ls` the existing submissions and read their
   `README.md`s. If someone already shipped a To-Do list, don't ship a
   second one — build a game, or a calculator, or go to Tier 2.
2. **Language-corner gap** — which *feature combination* is
   under-exercised? Nobody's stressed obligation-transfer across a module
   boundary yet? Nested label loops with namespaced events? Effect
   branches feeding a flow? The cockroaches live in the *combinations*.
   Pick a gap on this axis too, and say which one you targeted.

The existing submissions ARE the backlog. There is no TODO list to
consult — the catalog is the spec for what's missing.

## When you hit a wall (this is expected)

You will hit toolchain bugs. That is the *point*, not a failure. When the
compiler rejects something it shouldn't, or emits broken code, or crashes:

- **Do NOT work around it silently.** Do NOT contort your design to dodge
  it. Do NOT stuff the broken part into a proc body to make it disappear.
- **Pin it.** Reduce it to the smallest input that reproduces, and leave
  it as a **Frontier**: a failing test with a precise description of what
  you expected vs. what happened. A clean Frontier beats a forced green.
- Note it in your writeup. The human + Claude fix it together afterward —
  that joint fix is where the toolchain actually improves.

A submission can be: a clean working program, a working program *plus* a
pinned Frontier or two, or — if you hit a wall early — just a tight
Frontier. All three are real contributions.

## Where your submission goes

`tests/regression/800_CHALLENGES/800_NNN_<name>/` — the regression harness
only treats a directory as a test if its basename starts with a numeric
prefix (`^[0-9]+_`). A dir named just `tether` is **silently skipped** — no
error, no run. So use the next free `800_NNN_<name>` slot (short, lowercase
`<name>`, like `800_001_espresso`). Self-contained:

| File | Purpose |
|---|---|
| `input.kz` | Your Koru program |
| `MUST_RUN` | Marker: this test compiles + runs (empty file) |
| `expected.txt` | The deterministic output trace (the oracle) |
| `README.md` | The writeup (template below) — part of "done" |

A passing submission is auto-run by the regression suite forever and
swept into the corpus. For a Frontier, use `MUST_FAIL` + `EXPECT` + an
`expected_error.txt` pinning the diagnostic instead (see the regression
conventions in the repo's `CLAUDE.md`).

## "Done" looks like

1. The program compiles through all four stages and runs (or is a clean,
   precisely-pinned Frontier).
2. Koru does the work — phantom states / flows / obligations carry the
   structure, not a proc body. (An adversarial reviewer will check this.)
3. Output is deterministic and captured in `expected.txt`.
4. Verified live: corrupt `expected.txt` → fail, restore → pass.
5. Writeup filed at `<name>/README.md`.
6. You picked a real gap on *both* axes and said which.

Then stop. Don't ask if you should do another. If the human wants
another attempt, they spin up another contestant.

## Submission writeup template

```markdown
# <name>

**One-line pitch**: <what it is in ≤20 words>

**Tier**: tutorial | resource-lifecycle

## What it is
<3–6 sentences: what it does, what it demonstrates about Koru.>

## How Koru does the work
<Which events, flows, phantom states, obligations carry the structure.
Name them. This is the section the reviewer reads first.>

## Gaps I filled
- **Domain**: <what wasn't in the catalog before this>
- **Language corner**: <what feature combination this stresses>

## Frontiers hit (toolchain bugs)
<Each: smallest repro, expected vs. actual, where it's pinned. Or "none">

## Output
<One-line description of the trace in expected.txt.>
```

## First, read these

- This file's repo standards: `CLAUDE.md` + `AGENTS.md` at the repo root —
  binding. Especially "branches are equal," the `|>` layout rules, and
  phantom syntax (`<state>`, not `[state]`).
- `koru-by-example.md` — the canonical syntax oracle. Every shape you
  write should match something here. If you can't find a passing example
  of a shape you need, that's a red flag — pin it, don't invent it.
- A passing MUST_RUN test for the file conventions, e.g.
  `tests/regression/000_CORE_LANGUAGE/040_CONTROL_FLOW/203_labels_and_jumps/`.
- Run a single submission: `./run_regression.sh <name>`.

---

**Catalog upkeep**: when you ship, the submission dir + its README *is*
the catalog entry — the next contestant reads it to find a gap. The
catalog is the long-running artifact; each challenge is one slice through
it.
