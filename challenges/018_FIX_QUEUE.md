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

### Q1. Three verbs print an error and exit 0 — DRAINED 2026-08-15 (`310_123`)
```
koruc run       →  Error: no input file specified   exit 1   (was 0)
koruc build     →  same                             exit 1   (was 0)
koruc deps      →  toolchain report                 exit 0   (intentional: bare `deps` is the toolchain check)
```
`run`/`build` with no file printed an error then `return`ed from `main`, so
anything scripting `koruc` could not tell this from success. Now `exit(1)`,
pinned by `310_123_missing_input_exits_nonzero`. Bare `koruc deps` is a
different path (the toolchain check) and stays 0. The sibling `koruc deps
<module>` refusal was already `310_115`.

### Q2. `--check` passes a file that does not build
```
koruc --check bad.k   →  ✓ Shape checking passed    exit 0
koruc bad.k           →  error …                     exit 1
```
Same file. `--check` runs only the Koru shape pass and cannot see backend
errors, but says "passed" without saying what passed. Either the scope goes in
the message or the two verdicts must agree.

### Q3. `koruc <file> run` builds and never runs — DRAINED 2026-10-27 (`310_144`)
Byte-identical output to a plain build, exit 0 — trailing words in command
position are never forwarded, so every unmatched word was dead input. Now an
undeclared word there refuses: leading verbs (`run`/`build`/`lib`/`bundle`/`init`/
`create`/`skills`/`zen`) get "verb first, file second" plus the corrected line;
anything else gets "not a command the file declares". Flags in the slot stay
flags, declared comptime commands (`deps`, `explain`, …) still dispatch.
Pinned by `310_144_command_position_refuses_dead_words`.

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

- `isUsableAlias` rejects any `/` — MEASURED DRAINED 2026-10-27: binding keys
  now go through `isUsableModulePrefix` (per-segment check), and
  `std/vendor:bindings` shipped (`koru_std/vendor.kz`, KORU171).
- The `690_109` fix (see Q13) — MEASURED DRAINED 2026-10-27: both
  `690_109_bare_drain_arm_threads_its_column` and `690_107` compiled and ran
  correctly at HEAD (`inserted` / `cancelled 3`). The fix landed elsewhere;
  this queue row was a stale claim.

---

# 018 — SECOND RUN (2026-10-11), one hunter, the whole surface

Measured against `b57b07a5f` on `ch/quirk-2026-10-11`. Every command below was
re-run in a clean shell before landing here. **Eight new findings, each with a
red pin landed this run (`310_145`–`310_152`); seven on paths that work.**

## Status of the first run's queue

| Item | Verdict today |
|------|---------------|
| Q2 `--check` unscoped | Mostly drained — `--deep-check` exists and `--help` now scopes `-c` ("stops at the frontend"). The `✓ Shape checking passed` line itself still does not name its scope. |
| Q3 trailing-token swallow | **Still open, and wider than recorded.** See Q14. |
| Q4 init "Compile and run" | **Still open, verbatim.** `koruc init` still prints `koruc app.kz # Compile and run`; `koruc app.kz` still does not run. |
| Q5 init koru boilerplate | Shape changed — the scaffold's `koru.json` now carries `"paths": {"node": "./node_modules"}`; the `koru` boilerplate line is gone. |
| Q6 `std/explain` unimportable | Half drained — the stale `event` decl is fixed; `import std/explain` compiles and `explain` dispatches when the program imports it. The no-import path is still dead: see Q15. |
| Q7 `std/io:args()` | **Still live.** `ArrayList.init` is gone in Zig 0.15: `error: struct 'array_list.Aligned(...) has no member named 'init'`, plus host-path noise `.zig-cache/koru_lib_overlay/...` in the diagnostic. |
| Q12 examples rotting | Evolved — `downloads.k` and `demo.k` are newly stale: both use `! key`, renamed to `key-raw` in koru-libs `7d68858`. `koruc downloads.k` → KORU030 naming the correct arm list. The suite still compiles no example. |
| Q13 KORU161 on downloads | **RESOLVED.** `690_109` is green today (ran it); KORU161 no longer fires on downloads.k. The file's refusal now is KORU030 on the stale `! key` arm — a correct refusal of drifted source, verified by compiling a scratch copy with `key-raw` to full success. The standing lead is closed. |
| isUsableAlias lead | **Confirmed and pinned** — see Q18 / `310_149`. |

## New findings — the rung ladder, top first

### Rung 1 — two states, one observation

**Q14. Every unclaimed argv token is swallowed — commands, typos, filenames, flags.** `koruc app.kz zzzzzz`, `koruc app.kz bulid`, `koruc app.kz run`, `koruc app.kz out.zig`, and `koruc --depp-check app.kz` all produce byte-identical output to `koruc app.kz`: a clean build, `✓ Built executable`, exit 0. A valid command, a typo, a dead command, and an output filename are indistinguishable — and a documented position (`run` after the file) is indistinguishable from garbage. The `deps` fix cured one token; the general path (`main.zig` "Silently ignore other non-flag args") still swallows the rest, and flags fall into the same bucket (`compiler_config.addFlag`) the passthrough-flags concept already names.
*(A) tool wrong — the deps refusal is the toolchain's own precedent for exactly this.* (B) trailing tokens are "command args" — refuted by `zzzzzz`, which can be an arg to nothing. **Lean A — grounded** (the deps refusal text describes this behavior as the defect it fixed). Pin: `310_145`.

**Q15. `explain` is a declared command that can never dispatch.** `koru_std/explain.kz:45` declares it; its own doc shows `koruc main.k explain`. The `command=` provider atom (`main.zig:7556`) exists so `~[command(explain)]import std/explain` can ride along — **no such gated import exists anywhere**, so on any normal program `explain` falls into Q14's swallow, identical to a typo. Importing `std/explain` in the source makes it work ("📖 explain — no explainers registered").
*(A) tool wrong — the gate was built and never wired.* (B) explain is import-opt-in — but then its usage line lies, and a toolchain verb should not require the user to import its definition. **Lean A — grounded** (main.zig comment states the gate's purpose). Pin: `310_146`.

**Q16. `koruc` silently overwrites a user's `build.zig` — while diff-checking `build.zig.zon`.** A sentinel `build.zig` in cwd was replaced with generated content, zero warning; `build.zig.zon` in the same directory was checked and preserved ("unchanged"). Two files, same class, opposite treatment — the tool knows how to preserve and doesn't, for the file a user is most likely to have authored. Same observation whether it created or destroyed: `✓ Generated ./build.zig`.
*(A) tool wrong — silent data loss on a green path.* (B) cwd is koruc's scratch — refuted by the zon diff-check. **Lean A — grounded** (the asymmetry is the citation). Pin: `310_147`.

**Q17. `koruc <file> help` reports "No commands defined" while commands dispatch.** On a file importing `std/package`: `install`, `i`, `deps`, `glance` all run — `help` says none exist. Help enumerates the pre-merge entry AST; dispatch resolves post-merge. Two code paths answering one question, and the user-visible one is wrong.
*(A) tool wrong.* (B) help intentionally scopes to the file — refuted: "No commands defined in X" asserts none exist, and commands do. **Lean A — grounded** (live-verified both directions). Pin: `310_148`.

**Q21. A comment containing `import std/compiler` breaks the whole program.** The compiler-env injection scans raw source for the substring (`main.zig:7758`) — a `//` comment containing it satisfies the scan, the import never loads, and every `std/compiler:` host-type reference inside stdlib transforms fails KORU117 pointing at `koru_std/io.kz:26` — files the author never opened. "The import is present" and "the import is mentioned in prose" are the same observation. Found by accident: a pin's header comment described the mechanism and broke its own input.
*(A) tool wrong — feature detection by byte-scan counts prose as presence.* (B) can't construct one — the file is legal Koru either way. **Lean A — grounded** (the substring scan is the mechanism, reproduced with a two-line comment). Pin: `310_152`.

### Rung 5 — the surface speaks the wrong language

**Q18. `std/compiler:paths` refuses `koru/vaxis` citing a premise the resolver falsified.** KORU172: "an alias is a bare identifier … because every use site splits on the first `/`". False since `longestAliasMatch` (`module_resolver.zig:591` — docstring names `koru/vaxis` as a supported key). koru.json accepts the key; the source-level directive refuses it — two spellings of one declaration, different grammars. `isUsableModulePrefix` (the wider validator) exists one function below.
*(A) tool wrong — the refusal text teaches a rule that isn't true.* (B) deliberate asymmetry for source-level aliases — but the refusal claims mechanical impossibility, not design intent. **Lean A — grounded** (the lead from run one, confirmed live). Pin: `310_149`.

**Q19. `koruc --print` emits canonical source that cannot re-parse as `.k`.** On a `.k` file it prints `~`-prefixed spellings — the facet marker the `.k` grammar refuses (PARSE003) — and prepends `~import std/compiler` the source never wrote. Saved as `.k`: refuses at line 1. Saved as `.kz`: parses — but only if no same-stem `.k` exists, because the companion merge then parses *that* file and a failure there escapes as `error: ParseError` with a raw `???:?:?:` Zig stack trace, naming no file.
*(A) tool wrong — a canonical print must round-trip in the source's own facet, and internal parse failures must not leak stack frames.* (B) canonical print is host-facet by design — possible but unnamed anywhere, and the stack trace is indefensible under any reading. **Lean A — grounded** (round-trip reproduced both directions). Pin: `310_150`.

**Q20. `glance` and `--list-imports` report the injected compiler env as the program's surface.** A three-line hello world lists 15 modules / ~96 events: `std.compiler`'s pipeline (`coordinate`, `elaborate`, `emission`), `std.optimizer`, `std.rules`, `std.template` — none importable or nameable by the program. The author's own module appears only if it declares events.
*(A) tool wrong — "the program's declaration surface" should mean declarations, or mark env as env.* (B) honest whole-program view — the env does ride along. Plausible; then the listing still owes the distinction. **Lean A — inferred.** Pin: `310_151`.

### Unpinned observations

- **Companion `.k` parse failure escapes as `error: ParseError` + raw stack trace** (`???:?:?:` frames, no file named). Trigger for the merge correlates with `~import std/compiler` in the `.kz`; the exact gate is unmeasured.
- **`--help` teaches `.kz` as the only extension** — every example uses it; a pure-Koru `hello.kz` refuses with PARSE003 jargon. `.k`, the extension for the language a user came to write, is never mentioned.
- **Backend errors echo host paths** — `.zig-cache/koru_lib_overlay/std/...` and `output_emitted.zig:792` appear in user-facing diagnostics (seen on Q7's `args()` failure).
- **`-o custom.zig` silently skips the executable** — output ends mid-stream at "Generated ./build.zig" with no line stating what it did. The reports-what-it-did concept applies.

### Why the suite was blind — the new categories

6. **Argv the frontend doesn't claim is invisible to the harness.** Tests invoke `koruc` through fixed arg vectors; no test hands it an unclaimed token (Q14, Q15, Q17 — extends category 1).
7. **The cwd is never pre-populated.** No test runs `koruc` in a directory containing a user's own files, so overwrite-vs-create is unobservable (Q16).
8. **Raw-text feature detection is never tested against prose.** No test puts the trigger substring inside a comment or string (Q21) — the corpus's comments never name imports, so the scan was only ever measured against real code.
9. **Two enumerators for one set drift unchecked.** help's pre-merge command list vs. the dispatcher's post-merge set; glance's module list vs. the program's imports. Wherever two code paths answer the same question, the suite asserts only one (Q17, Q20).

### Open questions (unanswered spellings/rulings)

- Should trailing `run`/`out.zig` refuse or dispatch? (Pin `310_145` chooses refuse, matching the `deps` precedent.)
- Where do generated build files belong — a koru-owned name/dir, or refusal on collision? (`310_147` only pins "never silent".)
- What exactly triggers entry-companion merge? Correlates with `~import std/compiler` in the `.kz`; unmeasured beyond that.
- Is `glance`'s contract "the program's declarations" or "the whole merged program"? The pin assumes the former.

### Score

8 findings on working paths (Q14–Q21, all pinned red this run), 1 on a
misleading refusal (Q18, inside the same count), plus queue statuses. Zero
findings came from already-red paths — the downloads story this run is a
correct refusal, not a quirk.
