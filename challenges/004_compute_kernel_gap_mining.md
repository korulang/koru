# Challenge 004 — Compute-kernel gap mining

> Exercise the **language** by porting naive compute kernels through `koruc`, faithfully.
> Every kernel that won't go green in pure Koru names a gap — a missing language feature,
> a compiler bug, or a diagnostic that leaks host-level noise instead of speaking Koru.
> Mine those gaps. Toolchain-first: the kernels are **instruments**, never a scoreboard to
> win; a green is a *side effect* of the language becoming more capable, and the only green
> that counts. Each confirmed gap drains into a **minimal core pin** (a failing regression
> test in `koru`) or a documented, honest-red gap. Run it repeatedly against the board.

A standing **generative frame**, not a backlog. Specialized to compute kernels for now; the
same shape generalizes later (any assignable corpus of programs-to-port becomes a surface).
Only the *outputs* persist — merged green ports, confirmed pins, named gaps.

---

## The surface — the kernel board

- **Repo:** `koru-benchmarks` (sibling checkout, `../koru-benchmarks`; origin
  `github.com/korulang/koru-benchmarks`). Suite: `suites/osprey-compute-kernels/`.
  - `reference/cases/<name>/` — the faithful reference in five languages
    (`.osp/.rs/.c/.ml/.hs`) + `expected.txt` (the integer **oracle**) + `bench.json`.
    This is both the correctness oracle **and design input**: how other languages express a
    kernel is a candidate idiom for Koru, not merely a spec.
  - `koru/<name>/{<name>.k, expected.txt}` — the pure-Koru port + oracle.
  - `run.sh` — builds each port **through `koruc`** (`koruc build` → run `a.out` → compare
    oracle). It consumes the toolchain; it cannot fake a green.
- **Compiler:** `koruc` at `../koru/zig-out/bin/koruc` (build with `cd ../koru && zig build`).
- **Faithfulness rule:** same naive algorithm, same parameters as the reference — no
  memoization, no SIMD, no algorithmic shortcut. `expected.txt` is the reference oracle,
  unchanged. `for(a..b)` is `[a,b)`, matching Osprey `range(a,b)`.
- **State of the board (2026-07-03):** `josephus` ✓, `factorial` ✓ (SHOWN green). `gcdsum`
  red → confirmed compiler bug, pinned `koru/tests/regression/320_CONTROL_FLOW/
  320_121_tail_self_loop_parallel_assign`. First floated diagnostic gap: `for(a..b)` loop var
  is `usize`, and mixing it with an `i64` accumulator leaks a **raw Zig type error** instead
  of a Koru diagnostic. ~19 kernels unported — the assignable surface.

---

## Grounded idioms — DO NOT invent syntax (ground every line in the corpus)

Verified pure-`.k` forms (cite a passing `koru/tests/regression/**` test or an existing green
port before using anything else; if a form isn't in the corpus, that absence is likely a gap):

- **Scalar capture-fold** (the `range |> fold` equivalent):
  `capture { acc: 0[i64] } ! as a |> for(A..B) ! each i |> captured { acc: <expr over a.acc, i> } | captured r |> std/io:print.ln("{{ r.acc:d }}")`
- **Integer div/mod:** `@divTrunc(a, b)`, `@mod(a, b)`. Loop var `i` from `for(A..B)` is
  `usize` — bridge to `i64` with `@as(i64, @intCast(i))`.
- **Recursive value event:** `pub event f { .. } | value i64` then
  `f = if(cond) | then => value X | else |> f(..) | value v => value <expr with v>`.
  Note the confirmed split: **non-tail** recursion (transforms after the call) works;
  **tail** self-recursion whose args cross-reference is currently mis-lowered (pin 320_121).
- **Labeled loop:** `#L f(..) | again m |> @L(..) | ok r => ..` (search/counted loop).
- **Maps:** `std/map` (int keys), `std/string-map` (string keys), branches `| value v` / `| missing`.
- **Stdin:** `std/io:read-lines()` (line stream). Events in a `.k` file must be `pub`.

**Known-ABSENT — these ARE the gaps to confirm, not syntax to invent:** scalar `match n { 0 => .. }`,
first-class lambdas, recursive algebraic/union types (`type T = A | B { .. }` + destructuring
match), persistent list with `[head, ...tail]`, immutable string builtins (`length`/`contains`/
`startsWith`), `==` on strings.

---

## Perf gaps — when a kernel is green but slow

A green kernel is not the end. A kernel that passes the oracle but is slow against the
reference languages (`bench.sh`) is a **performance gap** — the same instrument, the
second axis. Perf gaps follow the **`koru-benchmarking`** skill
(`skills/koru-benchmarking/SKILL.md`): `NAIVE CODE => OPTIMAL BINARIES`, closed by
diagnosing from the Koru code first, then an emitted-Zig backport (measure-first, 1:1),
or a high-performance primitive — with the **optimization always landing in the
toolchain, never in the `.k`.** Read that skill before proposing any perf work: verify
ReleaseFast before trusting a number, time under the reference's own protocol, oracle-
gate, and let no "beats/matches X" claim leave the room unverified. The hard stance
below binds perf findings too — a slow kernel is a *toolchain* gap to name and propose
against, never a `.k` to hand-tune (that is faithfulness fraud).

## ⚖️ THE HARD STANCE — make a qualified guess, never a verdict (binding on EVERYONE)

When a port won't go green, there are always two readings, and they are **not yours to choose
between**:

- **(A) the toolchain is wrong** — a compiler bug (silent wrong answer, crash, bad codegen), a
  missing language feature, or a diagnostic that leaks host (Zig) noise instead of a Koru-level
  error.
- **(B) your port is wrong** — you misused an idiom, invented syntax, or broke faithfulness, and
  the language is fine.

You MUST give a **qualified guess** (A / B / unsettled) with `confidence` **defined by evidence**:
`grounded` = you cite a passing corpus test / the tool's stated contract / emitted code you read —
the only level where a hard lean is allowed; `inferred` = reasoning, no citation; `unsettled` = a
frontier with no prior art. A 50/50 shrug is forbidden. Write **both** readings in full even when
you lean A. You **NEVER edit `koru`'s compiler or stdlib, and you NEVER commit or "fix" anything** —
you produce port attempts and findings, and *propose* pins. The arbiters rule which side moves and
drain it, on the walk. Everything you report is a hypothesis grounded in something you actually ran
through `koruc`.

---

## For contestants (the brief, sealed)

Work against `../koru-benchmarks`. **Read the repo-root standards first** in both `koru` and
`koru-benchmarks` (`CLAUDE.md`, `AGENTS.md`). Build `koruc` once (`cd ../koru && zig build`).
For each assigned kernel: read its reference (`reference/cases/<name>/`), write a faithful
pure-`.k` port using only grounded idioms, and build it through `koruc build` in a scratch dir
(koruc clobbers its CWD). Reduce every red to a minimal repro before judging it.

Return one **finding per assigned kernel**:
- `kernel`, `status` (green / red)
- `port_source` — the exact `.k` you wrote
- `evidence` — the exact `koruc` command and its output (oracle match for green; the exact error
  or wrong value for red)
- If red: `minimal_repro` (smallest `.k` that still shows it), `divergence_class`
  (`compiler_bug` / `missing_feature` / `bad_error_message` / `port_wrong`),
  `reading_A_toolchain_wrong`, `reading_B_port_wrong`,
  `qualified_guess` {lean, confidence, prior_art},
  `proposed_pin` (target category under `koru/tests/regression/`, the `input.k`, the correct
  `expected.txt`) **or** `proposed_gap` (which absent feature, what it would take), `severity`.

Do NOT edit `koru`'s tracked source. Do NOT commit. Everything is a hypothesis — ground it in a
real `koruc` run. Worked example of a finding drained into a pin:
`320_CONTROL_FLOW/320_121_tail_self_loop_parallel_assign`.

---

## For arbiters (Lars + Claude)

On the walk, per finding: **verify before draining** — re-run the `koruc` command yourself; every
contestant claim is hypothesis. Then decide which side moves and drain the real ones:
- green port → merge it into `koru-benchmarks/suites/osprey-compute-kernels/koru/<name>/`;
- confirmed compiler bug → write the minimal pin in the sensible `koru/tests/regression/` category
  (MUST_RUN + correct `expected.txt`, red until fixed), then fix together;
- confirmed missing feature → keep the kernel honest-red and name the gap in the compiler's own terms;
- bad-error-message → the leak is itself a defect; propose lifting the wall to the Koru level.

**Never** "fix" the compiler to match a misread idiom (the mirror of conformance fraud). **Never**
let a sealed contestant settle which side is wrong. A merged green earned any way other than the
language genuinely getting more capable is worth less than the honest red it replaced.

## Pass / value contract

A run earns its keep when it produces **≥1 confirmed drainable outcome** the arbiters merge: a green
port that faithfully passes the oracle, a confirmed pin, or a confirmed-and-documented language gap.
Zero confirmed = the language already handles the probed kernels; move the probes to the next slice.
