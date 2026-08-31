# WALLS — the register of the suite's guards

A wall is a quality rule compiled into the harness so nobody has to remember
it. The failure mode of walls is being forgotten: a forgotten wall gets
measured against with the wrong predicate, rebuilt, or bypassed. This file is
the register, and `scripts/wall_check.sh` (run by the suite's coherence
watchers) keeps it honest in both directions: a guard added to the harness
without a row here fails the run (UNREGISTERED), and a row here whose guard
has left the harness fails the run (STALE / MISSING-ANCHOR).

Row kinds, machine-read by `wall_check.sh`:

- `verdict:<id>` — a literal the harness can write into a test's `FAILURE`
  file. This set is extracted from the harness sources, so it is complete
  over per-test verdicts by construction. Dynamic tails normalize to a family
  key (`leak-*`).
- check rows use the ids `prose-check:<letter>` and `registry:<bucket>`,
  extracted from `prose_check.sh` and `registry_check.zig`.
- `anchor:<id>` — a guard with no verdict of its own (runner refusals, locks,
  sub-walls sharing one verdict, walls spelled as tests). Columns 2 and 3 are
  a file and a literal that must still be present in it (`EXISTS` = the path
  itself must exist).

The **mirror** column records the direction of the same symmetry the wall
does NOT guard — the census question that found most of the defects this
register exists to prevent. An empty mirror cell means none is known, not
that none exists.

A third species is not in this file because it cannot be: an **accidental
wall** — an assertion that exists, works, and was written by nobody (see
`concepts/frag-a-test-can-be-load-bearing-by-accident.md`). There is no bulk
detector for it. The only known handle is a full board after every merge and
stopping on any unexplained flip.

## Per-test verdicts

| id | where | guards | mirror it does not cover |
| --- | --- | --- | --- |
| verdict:aoc-not-pure-koru | regression_lib.sh | 810_AOC_2015 is pure Koru: no host entry, no `~proc`/`@import` | greps `input.k` only — sibling `.k` files in the test dir are unchecked; no other pure-language cluster is guarded |
| verdict:ast-gen-empty | regression_lib.sh | a PARSER_TEST must actually produce AST JSON | |
| verdict:ast-mismatch | regression_lib.sh | PARSER_TEST AST must equal expected.json | |
| verdict:backend | regression_lib.sh | Stage B failure with no declared expectation is a failure | |
| verdict:backend-exec | regression_lib.sh | Stage C failure with no matched pin is a failure | |
| verdict:backend-missing | regression_lib.sh | the built backend binary must exist and be executable | |
| verdict:backend-move | regression_lib.sh | a failed binary move must not fall back to a stale backend | |
| verdict:broken-test | regression_lib.sh | a BROKEN marker fails the test instead of hiding it | |
| verdict:compile-only-lazy | regression_lib.sh | `input.kz` with runtime indicators must not pass as compile-only without MUST_RUN | reads `input.kz` only — a pure `.k` with runtime I/O and no MUST_RUN passes as compile-only |
| verdict:comptime-output | regression_lib.sh | expected_comptime.txt lines must appear, in order, in Stage C output | the gate lives inside the MUST_RUN branch; `expected_comptime.txt` on a non-MUST_RUN test is never read, though its own comment says it requires MUST_RUN |
| verdict:crash-* | regression_lib.sh | a MUST_RUN binary that exits abnormally fails even when its output matches — the exit code is graded alongside actual.txt | reads the exit code only; a program that returns 0 after corrupting state, or one killed by a signal its runtime swallows, is still invisible here |
| verdict:trap-exit-* | regression_lib.sh | an EXPECT_TRAP naming exit codes must die with one of them, so a pinned panic that becomes a segfault fails | the codes are authored per test; nothing checks that a declared code is one this platform can produce |
| verdict:trap-without-message-pin | regression_lib.sh | EXPECT_TRAP requires an output expectation, so a trap pins the message it dies with and not merely "something went wrong" | requires *an* expectation, not that the expectation names the trap — a trap test pinning only its pre-trap output satisfies this |
| verdict:expect-trap-but-exited-clean | regression_lib.sh | an EXPECT_TRAP test that exits 0 proves the pinned trap stopped firing | mirror of verdict:expect-timeout-but-finished; both cover a declared abnormal end that stopped happening, neither covers an undeclared one that started |
| verdict:config-error | regression_lib.sh | a self-contradictory or unpinned test configuration refuses to run — four sub-walls, anchored individually below | see the `anchor:cfg-*` rows |
| verdict:error-output | regression_lib.sh | an expected frontend error must match its pin | |
| verdict:expect-timeout-but-finished | regression_lib.sh | an EXPECT_TIMEOUT test that finishes proves the watchdog net broken | |
| verdict:expected-error-missing | regression_lib.sh | EXPECT names FRONTEND_COMPILE_ERROR but compilation succeeded | |
| verdict:failed | regression_lib.sh | nothing compiled and nothing declared an expectation | |
| verdict:frontend | regression_lib.sh | an unexpected frontend failure is a failure (never reuse a stale backend.zig) | |
| verdict:js-compile | regression_lib.sh | LANGUAGES js: the JS target must compile | JS equivalence covers positive MUST_RUN tests only; MUST_ERROR tests stay Zig-only (declared first-increment scope) |
| verdict:js-mismatch | regression_lib.sh | the JS target must satisfy the same expected.txt as Zig | |
| verdict:js-noemit | regression_lib.sh | a JS compile must emit a program, exit code alone is not trusted | |
| verdict:js-runtime | regression_lib.sh | the JS program must run clean under node | |
| verdict:leak-* | regression_lib.sh | a memory leak in any phase fails the test | |
| verdict:leak-output | regression_lib.sh | the produced program's own GPA check fails the test on leak | |
| verdict:must-error-passed | regression_lib.sh | a MUST_ERROR test that runs clean is a failure | |
| verdict:no-error-pin | regression_lib.sh | a Koru diagnostic (`error[KORU…]`) must be pinned; a bare stage marker is not enough | by policy the bare marker stays sufficient for raw host/Zig errors we do not own |
| verdict:no-exe | regression_lib.sh | MUST_RUN with no executable generated is a failure | |
| verdict:no-expected | regression_lib.sh | PARSER_TEST requires expected.json | |
| verdict:no-input | regression_lib.sh | a test dir with no input.kz/input.k fails | fires only for dirs already recognized as tests — an orphan `NNN_` dir with no input and no marker is invisible to the whole harness (mirror of prose-check:C) |
| verdict:output | regression_lib.sh | actual output must match expected.txt / patterns / EXPECT assertions | only expectations spelled in filenames the harness reads count — see anchor:cfg-expected-output-no-runner's mirror |
| verdict:post-validation | regression_lib.sh | post.sh exiting non-zero fails the test | |
| verdict:runtime | regression_lib.sh | a non-zero exit with no expectation declared is a failure | the mirror — a non-zero exit *with* an expectation declared — went ungraded from this wall's authoring until 2026-08-01, and is now verdict:crash-* |
| verdict:TIMEOUT after * | regression_lib.sh | the per-test watchdog SIGKILLs the whole process group on a compile hang | parallel path only; the serial path is deliberately unwatched (reasoned at its site) |
| verdict:timeout-* | regression_lib.sh | the run-phase timeout net catches a runaway binary | |
| verdict:wrong-error | regression_lib.sh | MUST_ERROR failed, but not with the pinned error | |

## Watcher checks

| id | where | guards | mirror it does not cover |
| --- | --- | --- | --- |
| prose-check:A | scripts/prose_check.sh | generated artifacts equal their regeneration; refuses under a live foreign suite instead of inventing a verdict | |
| prose-check:B | scripts/prose_check.sh | the by-example config carries no prose fields | |
| prose-check:C | scripts/prose_check.sh | no duplicate `NNN_NNN` test id | an orphan dir with no source at all — the commoner outcome of the same half-finished `git mv` — has no twin and is invisible |
| prose-check:D | scripts/prose_check.sh | every koru_std comptime transform has a mirror row (manifest: 115_COMPTIME_MIRROR/COVERAGE.md) | koru_std only; the koru-libs sibling repo is exempt by design |
| prose-check:E | scripts/prose_check.sh | a `NEEDS_RULING` marker (verdict blocked on an unmade decision) still describes its test — refuses one on a RUNNING test that passes, an empty one, and one next to no test at all | only fires where markers are live: a TODO-parked test's markers are exempt from cleanup, so a fossil SUCCESS there is not judged, and nothing here catches a question that was never written down or one whose stated question is the wrong question |
| prose-check:F | scripts/prose_check.sh | no committed `.k` carries a tilde — read from HEAD, not the working tree, because the incident that caused it (`git mv` stages, `sed -i` does not) ran green on every suite while the index shipped twenty tilde'd files; 210_203 excepted, since refusing one is what it pins | matches a tilde only at line start, and only under `tests/regression/**/input.k` and `koru_std/**/*.k` — a mid-line `~` (in a string, in a comment) is deliberately unexamined as a false-positive source, and a `.k` anywhere else in the repo is not looked at at all |
| registry:ORPHAN_EMIT | scripts/registry_check.zig | no diagnostic code is emitted without being declared | |
| registry:DEAD | scripts/registry_check.zig | no declared code goes unemitted without a reserved-list entry | |
| registry:ROTTEN_PIN | scripts/registry_check.zig | no test pins a code that cannot resolve | PINNED reads `expected*` and `EXPECT` files only — a pin expressed inside a `post.sh` is invisible to the registry |
| git-wall:committed | scripts/git_wall.sh | no tracked path matches .gitignore unless allowlisted (`scripts/git_wall_allowlist.txt`) | pre-commit `--staged` is the mirror for fresh junk; the allowlist must shrink, never widen without a purge |

## Anchored walls

| id | file | anchor literal | guards / mirror |
| --- | --- | --- | --- |
| anchor:cfg-both-expectations | scripts/regression_lib.sh | has both expected.txt and expected_patterns.txt | exactly one output-expectation form per test |
| anchor:cfg-expected-output-no-runner | scripts/regression_lib.sh | expected output but no MUST_RUN or EXPECT marker | an expectation implies running. MIRROR, unbuilt: `expected_error.txt` with no MUST_ERROR/EXPECT makes the rejection optional (acceptance also passes) |
| anchor:cfg-dead-expectation-filename | scripts/regression_lib.sh | a filename the harness never reads | the mirror of cfg-expected-output-no-runner, built 2026-08-06: `expected_output.txt` is read nowhere, so a MUST_RUN test carrying one asserts only "exited 0" — both `440_RESOURCE_BRIDGE` tests printed `FAIL:` and reported green for six days over a seam that had never worked. Resolved 25 live carriers: 11 promoted to `expected.txt`, 14 deleted as litter beside a real assertion |
| anchor:cfg-comptime-requires-mustrun | scripts/regression_lib.sh | expected_comptime.txt but no MUST_RUN | the comptime channel's copy of cfg-expected-output-no-runner: the gate only runs under MUST_RUN, so the expectation would never be read |
| anchor:cfg-must-error-and-must-run | scripts/regression_lib.sh | carries both MUST_ERROR and MUST_RUN | a test cannot demand both a clean run and a rejection |
| anchor:cfg-must-error-unpinned | scripts/regression_lib.sh | MUST_ERROR test pins no diagnostic | a negative test names WHICH rejection it pins. MIRROR, unbuilt: an EXPECT line that is neither a known stage marker nor a recognized assertion is silently ignored — a misspelled assertion is silently no assertion |
| anchor:backend-koru-diag-pin | scripts/regression_lib.sh | Backend error has no pin | the backend twin of no-error-pin |
| anchor:zero-match-refuse | run_regression.sh | No tests matched: | a filter matching zero tests refuses instead of printing green |
| anchor:partial-match-refuse | run_regression.sh | Filter(s) matched no tests: | the mirror of zero-match: a request whose every pattern matches nothing refuses the whole run upfront, instead of silently answering only the names spelled right |
| anchor:machine-lock | run_regression.sh | already running on this machine | one suite per machine unless overridden |
| anchor:checkout-lock | run_regression.sh | is already active in this checkout | artifact corruption guard, no override |
| anchor:untested-fails-the-run | run_regression.sh | NO_MARKER_COUNT | a test that produced no marker fails the run rather than vanishing |
| anchor:unit-test-gate | run_regression.sh | UNIT TESTS FAILED | green regressions cannot outvote red unit tests |
| anchor:cache-parity | run_regression.sh | PARITY VIOLATION | --verify-cache asserts cached and uncached verdicts agree |
| anchor:watchdog-process-group | scripts/regression_lib.sh | run_one_test_watched | a hung test is killed as a whole process group and recorded loudly |
| anchor:snapshot-knows-benchmark | scripts/save-snapshot.js | BENCHMARK | the snapshot writer honours the marker the runner honours (the gap once produced months of `untested`) |
| anchor:variant-coverage-watcher | run_regression.sh | check_variant_coverage.py | every emittable koru_std helper symbol has a witness in some test's output_emitted.zig; covers only `__`-symbol-bearing variants — anonymous-code variants, the \|js target, src/ emitter templates, and other-host `--build` variants are out of its reach (invariants/checks/check_variant_coverage.py states each) |
| anchor:std-compiles-lint | scripts/std_compiles.sh | EXISTS | the koru_std rot lint — manual invocation only (`--std-compiles`), so it is itself a wall that must be remembered |
| anchor:test-wall-690_099 | tests/regression/600_STDLIB/690_STORE/690_099_unknown_store_still_refuses_under_the_guard | EXISTS | a wall spelled as a test: goes red if the store-name guard loosens from prefix-anchored to substring |
| anchor:test-wall-110_029 | tests/regression/100_MODULE_SYSTEM/110_IMPORTS/110_029_koru_alias_is_a_default | EXISTS | a wall spelled as a test: imports a module that cannot exist, so it asserts the alias rather than the author's machine |
| anchor:test-wall-990-watchdog | tests/regression/990_WATCHDOG_SELFTEST | EXISTS | the timeout net's self-test cluster: a hang must be caught, and a catchable hang that finishes is itself a failure |
| anchor:git-wall-precommit | hooks/pre-commit | git_wall.sh | pre-commit refuses staged paths .gitignore rejects and orphan lockfile pairs |
