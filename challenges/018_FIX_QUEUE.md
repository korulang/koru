---
challenge: quirk-hunt
kind: queue
status: open
yields: the standing fix queue drained from the first 018 run
family: toolchain
---

# 018 — FIX QUEUE (run of 2026-07-31)

Four hunters, four surfaces: the CLI, `koru-examples`, first-hour programs,
diagnostics. **21 findings; 14 reproduced by hand before landing here; 1
refuted.** Nothing in this file is an agent claim alone — each entry below was
re-run in a clean shell.

Ordered by the frame's own ladder. **Rung 1 first: two states, one observation.**

---

## Rung 1 — two different states produce the same observation

### Q1. Three verbs print an error and exit 0
```
koruc run       →  Error: no input file specified   exit 0
koruc build     →  same                             exit 0
koruc deps      →  same                             exit 0
```
Anything scripting `koruc` — CI, a Makefile, a hook — cannot tell this from
success. The sibling branch that refuses `koruc deps <module>` calls
`std.process.exit(1)`; these do not.

⚠️ One agent reported `deps` as the *correct* control. It is not — all three
exit 0. The bug is broader than the report.

### Q2. `--check` passes a file that does not build
```
koruc --check bad.k   →  ✓ Shape checking passed    exit 0
koruc bad.k           →  error …                     exit 1
```
Same file. `--check` runs only the Koru shape pass and cannot see backend
errors, but says "passed" without saying what passed. Either the scope goes in
the message or the two verdicts must agree.

### Q3. `koruc <file> run` builds and never runs
Byte-identical output to a plain build, exit 0. Only the leading form
`koruc run <file>` executes. `--help`'s own usage line is
`koruc [options] <input.kz> [command]` — the trailing form it documents is the
one that silently does nothing. Any unrecognised word in that position is
swallowed the same way.

---

## Rung 2 — the tool claims something it did not do

### Q4. `koruc init` contradicts itself inside one command
It prints:
```
Next steps:
  koruc app.kz       # Compile and run
```
`koruc app.kz` does not run (Q3). The `app.kz` it writes *in the same breath*
says `// Run with: koruc app.kz && ./a.out`, which is correct. **Two artifacts
from one invocation disagree about the tool's own behaviour, and the one a user
reads first is wrong.**

### Q5. `koruc init` still writes the boilerplate `2a34fc9f` abolished
The scaffolded `koru.json` carries `"koru": "./node_modules/@korulang"` — the
exact line that commit made a compiler default the same day. The fix landed in
the resolver and never reached the scaffold, so every new project still gets it.

---

## Rung 5 — the surface speaks the wrong language, or is unreachable

### Q6. `std/explain` cannot be imported at all
`koru_std/explain.kz:38` is the **only** stale `event` declaration left in the
stdlib after the `event`→`tor` rename — every file was checked. So the
documented `explain` command is unreachable twice over: without the import it
silently no-ops (Q3); with it, a hard `PARSE003` pointing into stdlib source the
user never wrote.

### Q7. `std/io:args()` does not compile
Its proc body uses `std.ArrayList(T).init(allocator)`, removed in Zig 0.15 —
and 0.15.2 is what we ship and what `koruc deps` reports as ✓ satisfied.
**Zero tests reference `:args()`.** Reading argv is about as first-hour as a
surface gets.

### Q8. A missing comma corrupts the diagnostic
A multi-line store seed block missing one separator produces an error whose type
name contains **the next field's entire declaration**:
```
error[KORU161]: … field 'label' is i64
done: i64 — columns are scalars …
```
The separator is not required at parse time, so the semantic pass echoes raw
merged text.

⭐ **Why nobody hit it: 103 store tests use single-line seed blocks; 2 use
multi-line.** A user hand-formatting a multi-column store for readability lands
on a shape the corpus has effectively never exercised. This is the frame's whole
thesis with a number attached.

### Q9. `for([1, 2, 3])` splices the literal into Zig
```
error: expected ']', found ','   →  for ([1, 2, 3, 4, 5]) |__koru_item_0| {
```
Array-literal lowering is wired per call-site (`const`) rather than per grammar
position. Binding to a name first works.

### Q10. `capture { total: 0 }` fails where `const` accepts a bare literal
`declarations.kz` claims the two have "the same argument shape". They diverge on
untyped literals, and the error names an internal Zig struct rather than
anything the author wrote. `capture { total: 0[usize] }` works.

---

## Docs

### Q11. The first example in `koru-by-example.md` does not compile as printed
The doc's header claims *"Every example below is verbatim source from a passing
POSITIVE regression test."* Example 1 — labelled "the frontpage example from
korulang.org" — fails with `KORU114`.

**The test is fine.** `010_000_hello_world_koru` is a legitimate three-file
multi-target test, and its `input.k` + `input.kz` companion pair compiles and
runs correctly as two files (verified: prints `[DEBUG] Hello, World!`). The
generator flattens both into one ```koru block, and as one file it cannot work.

**1 of 22 examples, and it is the first one.** The rendering is the defect, not
the test.

---

## `koru-examples` is rotting, and nothing watches it

### Q12. `gallery.k` and the `todo` flagship do not compile
Both use the retired `entity.` projection-block syntax. **The compiler is
correctly refusing** — `690_089` pins that refusal and is green. A stdlib syntax
retirement landed its migration burden on the in-tree corpus and never on the
showcase. `todo_store.k`'s own header claims *"Everything here builds + runs
through koruc today"* — present tense, false.

⚠️ That repo was being hand-edited while this ran; some may already be in flight.

### Q13. `KORU161` on `downloads` — ANSWERED
Lars's ruling was right: the compiler is wrong there. And **the pin already
exists and is already red** — `690_109_bare_drain_arm_threads_its_column`,
identical message, same construct, with a header ruling the bare form legal.
`690_106` (fully named) passes; `690_107` (label omitted) is red.

⭐ So the blindness is **not "no test."** It is that a red pin ships and
`koru-examples` is compiled by nothing, so the same defect surfaces twice with
nothing connecting the two. ⛔ Do not edit the example to silence it.

---

## ⛔ REFUTED — do not re-open

**"Omitting the last declared branch fires an unrelated error at the wrong
line."** Reported with a three-way symmetric test. It does not reproduce: first,
middle and last omission all give the correct `KORU022` naming the right branch.
Something in the reporter's fixture differed from what it described.

---

## The categories of blindness behind these

Naming the category matters more than the individual fix — it is what makes the
next run find different things.

1. **No test asserts what a CLI verb prints, and none invokes `koruc` with no
   file.** That entire class of misuse is outside the harness's imagination —
   Q1–Q5 all live here.
2. **A public stdlib surface with zero tests** (Q7 `args()`, Q6 `std/explain`) —
   the same category as the `koru/` alias bug that started this frame.
3. **The corpus exercises its authors' idioms** (Q8: 103 single-line vs 2
   multi-line) — the reason hunting inside the corpus finds nothing.
4. **A derived artifact is never round-tripped through the compiler** (Q11).
5. **`koru-examples` is compiled by nothing** (Q12, Q13).

## Standing leads not closed by this run

- `isUsableAlias` rejects any `/`, so `koru/vaxis` cannot be a source-declared
  alias — on grounds the longest-match change made false. This is the piece
  `std/vendor:bindings` needs.
- The `690_109` fix itself (see Q13) — a fix waiting for someone, not a question.
