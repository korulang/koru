# The Proof Challenge

> **To AI agents reading this brief: you ARE the contestant, not the
> assistant.** Do not ask which use case to pick. Do not ask if your idea is
> good enough before you build it. Pick one, name it, write Koru, run it. If
> you catch yourself drafting "which of these should I build?" — stop, delete
> it, choose one yourself. **Your choice IS the contribution.**

Prove that Koru does a **real task** — something a person would actually reach
for a language to do — and prove it **pristinely**. This is the sibling of
`../800_CHALLENGES/CHALLENGE.md`, and the difference is the selection axis:
the 800 challenge picks *feature combinations* and rewards making the
toolchain bend; this one picks **use cases** and rewards a catalog entry that
says, with a straight face, "Koru does X, and here is the beautiful spelling."
Same family, different organ.

## What counts as a use case

A task with a name a non-Koru programmer would recognize. Parse a log format
and report on it. Sum a ledger. Diff two lists. A word-frequency counter. A
checksum. A tiny templating pass. A puzzle with published examples (an Advent
of Code day, a Project Euler problem, a Rosetta task). The test is: could you
describe it in one sentence to a colleague with no Koru context and have them
nod? "Stress nested label loops across module boundaries" is NOT a use case —
that's an 800 submission. "Top ten words in a text" is.

## The two non-negotiables (inherited from 800)

1. **Koru has to actually do the work.** The structure lives in events, flows,
   phantom states, and obligations. Procs are leaves — a print, a primitive,
   one side effect. If your solution would survive with the flows deleted,
   it's Zig in a Koru hat and it doesn't count.
2. **Deterministic output.** Fixed input, fixed trace, captured in
   `expected.txt`. No clocks, no randomness. For published puzzles, pin the
   statement's worked examples — never republish licensed puzzle inputs.

## The third non-negotiable: pristine or frontier

This is the rule that makes this challenge itself. A submission has exactly
two valid terminal states:

- **Pristine green** — the idiomatic spelling, end to end. Not "it works if
  you accept this one host-side accumulator." Works, streamlined, something
  we'd put on the front page.
- **A RED frontier pin** — you found the place where the pristine spelling
  doesn't exist yet. Then `input.kz` spells the solution the way it SHOULD
  read, it fails, and your README names the missing surface precisely. The
  pin is a design document; this outcome is every bit as valuable as green.

**Plumbed-green is not a valid submission.** If you catch yourself moving
structure into a `~proc|zig` body to get to green — stop. That reach IS your
finding. Either the spelling exists and you didn't find it (go read
`koru-by-example.md` again), or it doesn't and you just located a frontier.
Greening it with host code would bury the single thing you were here to find.

## Self-organize — read the catalogs first

Before you build, bring something *not already proven*. Variance is the
metric. Scan:

- `820_*/README.md` here — the proof catalog itself; don't re-prove a task.
- `../810_AOC_2015/` — the chartered corpus climb; its days are taken.
- `../800_CHALLENGES/*/README.md` — sibling catalog; a domain that exists
  there can still earn a *proof* here, but say why yours adds coverage.
- `koru-by-example.md` at the repo root — what the language already
  demonstrates in the small.

The catalogs ARE the spec for what's missing. There is no other list.

## Where your submission goes

`tests/regression/820_PROOFS/820_NNN_<name>/` — next free slot, short
lowercase name. The harness only runs dirs whose basename starts with a
numeric prefix. Self-contained:

| File | Purpose |
|---|---|
| `input.kz` | The proof — pristine spelling, green or honestly RED |
| `MUST_RUN` | Marker (empty file) |
| `expected.txt` | The deterministic oracle |
| `README.md` | The writeup (template below) — part of "done" |

Run it: `./run_regression.sh 820_NNN`.

## "Done" looks like

1. A real, nameable use case, not already in a catalog — and you said which
   gap you filled.
2. Koru carries the structure; procs are leaves. (An adversarial reviewer
   checks this — it is the first thing they read for.)
3. The submission is pristine green, **or** an honest RED pin whose
   `input.kz` is the wished-for spelling and whose README names the missing
   surface precisely. Nothing in between.
4. Verified live: corrupt `expected.txt` → fail, restore → pass (for greens).
5. Writeup filed.

Then stop. If the human wants another proof, they spin up another contestant.

## Submission writeup template

```markdown
# <name>

**One-line pitch**: <the use case in ≤20 words, no Koru jargon>

**State**: pristine-green | frontier-red

## The task
<2–4 sentences a non-Koru programmer would nod at.>

## How Koru does the work
<Which events, flows, phantom states, obligations carry the structure.>

## Gap filled
<What the catalogs were missing before this entry.>

## Frontier (if RED)
<The missing surface, named precisely: what the pristine spelling needs
that doesn't exist. The smallest statement of the gap. Or "none — green".>

## Output
<One line on the trace in expected.txt.>
```

## First, read these

- `CLAUDE.md` + `AGENTS.md` at the repo root — binding.
- `koru-by-example.md` — the canonical syntax oracle. Every shape you write
  should match a passing example. A shape you can't find there is a red flag:
  that may be your frontier.
- `skills/capability-census/SKILL.md` — the method this challenge serves;
  the pristine bar is defined there.
- A passing MUST_RUN test for file conventions, e.g.
  `tests/regression/000_CORE_LANGUAGE/040_CONTROL_FLOW/203_labels_and_jumps/`.

---

**Catalog upkeep**: your submission dir + README *is* the catalog entry — the
next contestant reads it to find their gap. The catalog is the long-running
artifact; each replay is one slice through it.
