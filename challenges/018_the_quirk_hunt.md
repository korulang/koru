---
challenge: quirk-hunt
kind: frame
status: standing
yields: quirks found on paths that already work, each pinned by the test that should have caught it
family: toolchain
---

*Walker context — the recurrence that earned this frame. On 2026-07-30/31 Lars
spent one day using the toolchain as a user — writing programs, compiling them,
reading what came back. That day produced **five bugs and six commits**:*

```
2a34fc9f  feat(config): `koru` is a default import alias, like `std`
9423744d  fix(cli): a command run reports the command
209b72be  fix(cli): stop claiming a build that did not happen
ec21ed07  fix(cli): `koruc deps <module>` is the swap, and it is refused
b59e293e  fix(deps): a library's declarations are reachable, not one level down
f1a74bd1  fix(harness): zero tests matched is a failure, not a pass
```

***The suite carried 1363 tests that day and caught none of them.*** *One of the
examples could not compile at all. And four of the five shared a single shape:*

> *the broken path and the working path produced the same observation, so nothing
> could tell them apart — including the suite's own verdict.*

*The board mines what is **red**. `004` ports a kernel until it is blocked. `005`
claims a standing red and reads it. `002` operates the **machine** cold. Every one
of those starts from something that is already failing.*

***This frame mines the green.*** *It starts from paths that work and asks whether
they work **well** — and the day's evidence says that is where the findings are.*

---

## The brief (sealed — you are the contestant)

**Use the toolchain. Write programs you actually want to write. Report what was
odd.**

Not what was blocked — blocked is `004`. Not what is red — red is `005`. **Odd.**
Output that misleads, a message that overclaims, a success that looks like a
failure, a failure that looks like a success, two paths that report identically,
a flag that means something other than what it says, a diagnostic that names
something you did not write.

Return **4–8 findings**. A finding on a path that *worked* is worth more than one
on a path that failed, because the failing paths already have three frames aimed
at them.

## The finding class this frame wants

Rank your findings by this ladder. The top of it is where the day's five bugs
lived:

1. **Two different states produce the same observation.** The highest-value class
   by a wide margin. `koruc` printed the same thing whether a build happened or
   not; the harness reported a pass whether tests ran or not. Nothing downstream —
   no human, no test, no CI — could distinguish them. **Anywhere the tool cannot
   tell you which of two things happened, that is the finding.**
2. **The tool claims something it did not do.** "✓ Command finished" after a
   command that built nothing. Standing doctrine: *tell the user what the compiler
   DID.* State the positive fact.
3. **Compensation prose.** A negation, a parenthetical caveat, a clause explaining
   what is *not* claimed — `✓ Command finished (no executable built)` should have
   been `✓ deps`. See `feedback_no_compensation_prose_in_artifacts`; it is a
   standing correction from 2026-07-31 and the tell is easy to grep for.
4. **Boilerplate that answers a question the program should not be asked.** Nine
   examples each carried a config file whose entire content was one line. The fix
   was not a better config format — it was the realisation that "where does the
   ecosystem live" is not a question a program should answer.
5. **A diagnostic that speaks the wrong language** — host-level noise, an internal
   symbol, a path the author never wrote, a spelling the file does not use (a `.k`
   file gets no tilde).
6. **Ordinary friction** — a step that should not exist, a guess you had to make.

## Ground yourself FIRST

**Build once, then stop reading and start writing.** The failure mode of this
frame is a contestant who reads the compiler instead of using it. You are the
user. Your ignorance of the internals is the instrument — spend it before you
lose it.

**Work in `koru-examples` and in programs you invent.** The regression corpus is
poor hunting ground: it is written by people who know the answers, so it exercises
the author's idioms rather than a user's. `human-doodle` could not compile at all
and no test noticed, because no test looks there.

**Exercise every CLI verb, not just compilation.** The day's five bugs were
disproportionately in `koruc`'s *other* commands — `deps`, `run`, command
dispatch. Try `glance`, `explain`, `deps`, `run`, `--ccp`, bare `koruc`, a
misspelled verb, a verb with a missing argument, a verb with an argument it does
not take.

**Two live leads, already known, not yet diagnosed:**
- **`KORU161` fires on `koru-examples/downloads.k`.** Lars's read is that *the
  compiler is wrong there*, and nobody has looked. ⛔ Do **not** edit the example
  to make it go away — that was the sharpest correction of the whole arc.
- **`isUsableAlias` rejects any `/`**, so `koru/vaxis` cannot be a source-declared
  alias. The stated grounds — "every use site splits on the first `/`" — were made
  false by the longest-match change that landed the same day.

## ⚖️ Make a qualified guess, never a verdict

Same hard stance as `002`, and binding here for the same reason. There are always
two readings and they are not yours to choose between:

- **(A) the toolchain is wrong** — a real quirk, bug, or misleading surface.
- **(B) your expectation is wrong** — it works as intended and you misread it.

Write **both** in full, then lean, with a confidence set by evidence:
`grounded` (you cite the tool's own stated contract — a `--help` line, a header
comment, a passing test) is the only level where a hard lean is allowed;
`inferred` is reasoning without a citation; `unsettled` is a frontier. **A 50/50
shrug is forbidden.**

⛔ **Do not invent Koru syntax.** If your program needs a spelling that does not
exist, that is a finding — bring the question and the evidence. Never synthesize
a spelling from analogy, and never "just for now." Read a passing test or say
plainly that it is a guess.

## The durable output: the test that should have caught it

This is what makes the frame compound rather than repeat.

For every confirmed finding, the deliverable is not only the fix — it is
**the regression test that would have caught it**, and an honest answer to
*why 1363 tests did not*.

The day's five bugs each had a specific reason the suite was blind:

- **No test imported `koru/` at all.** The alias was exercised only by
  `koru-examples`, which the suite does not compile.
- **No test asserted what a CLI verb printed** — only that compilation succeeded.
- **The harness itself could not tell "all tests passed" from "no tests ran."**

Each of those is a *category* of blindness, not a missing test. Name the category.

And make the pin **machine-independent**: `110_029` is the model — it imports a
module that *cannot* exist, so it asserts the alias is known rather than that a
library is installed. A test that passes because of what is installed on your
machine will fail on a clean checkout, and that is a worse outcome than the quirk.

## What "done" looks like

- 4–8 findings, each with the exact command, what it printed, and what you
  expected — ranked on the ladder above.
- For each: both readings, a qualified guess, a confidence with its grounds.
- For each confirmed one: the test that should have caught it, and the **category
  of blindness** that let it through.
- Findings on **working paths** counted separately from findings on failing ones.
  If every finding came from something that was already broken, this frame did not
  run — it ran `005` by accident.
- Any spelling question written down, unanswered.

## Failure modes

- **Reading the compiler instead of using it.** Your inexperience is the tool.
- **Hunting in the regression corpus.** It exercises its authors' idioms.
- **Fixing the example to silence the compiler.** `downloads` should not compile;
  the compiler is broken about it.
- **Reporting a defect you never reproduced.** One report in the source day was a
  harness defect that did not exist — the shell was the problem and it went
  unquestioned. Re-run in a clean shell before you write it up.
- **Only finding red things.** Three other frames already do that. Mine the green.
