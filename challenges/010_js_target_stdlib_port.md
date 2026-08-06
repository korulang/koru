---
challenge: js-target-stdlib-port
kind: commission
status: standing
yields: the JavaScript target's stdlib surface, module by module, against a total oracle
family: js-target
created: 2026-08-06
---

*(Walker context, not part of the sealed brief. Written at the end of the session
that took the JS target from 45/220 to 400/491, so the next session starts where
this one stopped rather than re-deriving it. This is a **commission**, not a
standing generator: it is finished when the stdlib surface is ported. It appears
in the registry under open commissions, never in the replay menu.)*

---

## Where the JS target actually is

Run these before believing any number here; they are cheap and they re-ground:

    ./scripts/js-parity-map.mjs            # buckets, stdlib surface, blocking modules
    ./scripts/js-parity-map.mjs unlock     # ranked port order
    ./scripts/js-scan.mjs --bucket emitter --jobs 8    # the board, ~14 min

State at 2026-08-06, commit `b83df40f`:

| | |
|---|---|
| emitter-testable | **400 / 491 (81.5%)** — zig-green 373/439 (85.0%) |
| blocked-on-stdlib | 383 |
| blocked-on-test-host | 64 |
| Zig board | 1376/1520, **zero regressions** from any of this work |

The `zig-green` figure is the one the real closer would report; `js-scan` also
measures tests whose Zig baseline is red, and never blends the two.

## The oracle, and why it cannot be gamed

`scripts/js-scan.mjs` compiles each test with `--lang=js`, runs the emitted JS
under node, and compares stdout+stderr against the **same `expected.txt` the Zig
target already satisfies**. It is measure-only: it never touches SUCCESS/FAILURE.

Editing an `expected.txt` to make JS agree would break the Zig baseline for that
same test, which the real closer checks first. There is no way to move the
target; only the compiler moves. Treat the scan scripts and `docs/js-parity/` as
untouchable, and diff them at judge time — that check has been run on every
contestant so far and has always come back clean.

`js-scan` runs a **known-green control** before measuring anything. If the
control fails the run aborts, because a dead backend reports every test as
`js-compile`, and a slice reading `0/N all js-compile` is indistinguishable from
a genuinely hard slice. See `frag-zig-build-does-not-compile-all-of-src`.

## The three port kinds — get this right before estimating anything

The map reports two, and the corpus has three. Misclassifying one produces Zig
source inside emitted JavaScript.

1. **Runtime proc** — `~proc name|zig`, body is host code that runs in the
   emitted program. Port = a `|js` body. Try a bare `<module>.kjs` sibling
   first; the contract can stay in the `.kz`. This worked for ~300 test
   fixtures; whether it holds for every stdlib module is still open, and each
   port should report which was needed.
2. **Transform proc** — `~[transform]proc name|zig`, or a plain `~proc` whose
   EVENT carries `[comptime|transform]` on the `tor`. The body is Zig on every
   target — it runs inside the compiler and *emits* code. Port = a `|js`
   variant that emits JavaScript, staying in the `.kz`. Never a `.kjs`.
   **Reading only the proc line misses the annotation when it sits on the
   event** — that mistake classified `kernel:init` as a portable 27-test win
   when it is the Zig-only MLIR/GPU backend.
3. **Synthesized proc** — minted by a transform at compile time, belonging to no
   source file. `store` mints ~20 of these; all 23 `ast.ProcDecl` literals in
   `koru_std/` hardcode `.target = "zig"`. No `.kjs` can host them and no
   template renders them today.

## The ranking, and the two traps

`fs:read-lines` is one proc in an 87-line file reached by 66 tests. `store:new`
is one of eight procs in 8,734 lines reached by 160. Sort by tests-per-line-read,
not by tests.

- **NEVER port `kernel`.** It is the MLIR/GPU backend, Zig by construction, and
  the Elm-shaped JS thesis in `JS_TARGET_SPIKE.md` never targeted it. The map
  mis-ranked it once; do not let it back on the list.
- **`interpreter` and `runtime` are a whole interpreter** — 4257 lines, 30 `|zig`
  procs, 340 uses of `std.`/allocators. 19 tests sit behind it. Out of scope
  until someone rules otherwise.

## Store — the prize, and it is a refactor with a total oracle

Store blocks 161 tests, 130 of them solely: comfortably the largest single item
left. It looked like the scariest because of its size. It is not, once the shape
is clear.

Store's procs are **transforms** — `~[transform]proc new|zig` and siblings — so
they need no contract extraction and no `.kjs`. What blocks a `|js` rendering is
that store builds its generated bodies with **243 `allocPrint` calls**: Zig
source assembled as strings. There is no template to give a second rendering of.

The worked precedent is `koru_std/declarations.kz:49-58`, which has
`~proc const|template|zig` and `~proc const|template|js` — two Liquid renderings
of one template, diverging only where the hosts genuinely differ (`f.zig`
pre-lowered vs `f.value` verbatim). Both live in the `.kz`.

So the path, in order:

1. **Extract `store.k`** — the contract. Not for facet mechanics (transforms need
   no `.kjs`) but because contract and host are currently tangled, which is what
   let `.target = "zig"` get hardcoded at 23 synthesis sites.
2. **Convert the `allocPrint` assembly into templates**, Zig side only. This is
   the bulk, and it has a **total oracle**: behaviour must not change, so the
   board holding at its current number is a complete and ungameable check. No
   design decisions, no JS involved, fully incremental — one generator at a time.
3. **Add the `|template|js` renderings.** Additive, with a worked example.

A rewrite becomes a refactor with a perfect gate. Phase 2 is also parallel-safe
per generator and does not contend with the cheap runtime ports.

## How to run a wave, from what worked

- **Slice by module or by failure family, one contestant each.** The failure
  histogram in `docs/js-parity/clusters.json` is derived from the last full scan
  and IS the fan-out map — do not hand-write one, it goes stale within a wave.
- **Name a single owner for `src/js_emitter.zig`** in the brief, from the start.
  Four contestants landed hunks in it before an ownership ruling arrived; git
  merged them cleanly, but one conflict needed hand resolution and a five-way
  merge left a dangling identifier that killed the whole target.
- **Require the control check after every build**, not `zig build`.
- **Verify every factual claim in a brief against the code before sending it.**
  Three briefs in this session carried errors, all from trusting a document over
  the tree. `JS_TARGET_SPIKE.md`'s "STILL ASYMMETRIC" note was two months stale
  and cost six agents a workaround they did not need.
- **Ask for the split**: how much movement came from fixtures versus from the
  emitter. Blended, the number hides which kind of work is paying.

---

## The brief (sealed — you are the contestant)

You ARE the contestant. Pick the module named in your commission, or the top of
`./scripts/js-parity-map.mjs unlock` if none was named. Do not ask which.

Before anything else, read the repo-root standards: `CLAUDE.md` and `AGENTS.md`.
They bind everything you do.

Your progress is measured by `./scripts/js-scan.mjs`, which you MUST NOT modify,
along with `scripts/js-parity-map.mjs`, anything under `docs/js-parity/`, and
every `expected.txt`. Build the list of tests your module blocks from
`./scripts/js-parity-map.mjs json` and measure it before and after.

Determine which of the three port kinds above your procs are, from the source
and not from the module's name. Port them. Prefer a bare `<module>.kjs`; extract
a `<module>.k` contract only if that genuinely fails, and report which was
needed.

You are editing SHARED stdlib code. A `|js` proc should be additive and invisible
to the Zig target — **prove that rather than assuming it**: compile at least
three affected tests for the default target and diff their output against
`expected.txt`. Never run the full suite; breadth is the arbiter's gate.

Commit incrementally. The commit gate requires `## World Model` and
`## Membrane` sections; never bypass it with `--no-verify`.

Report your module's before/after, the port kind you found with its evidence,
which facet shape was needed, and one of three honest outcomes: **Bridge**
(it works), **Breakthrough** (it needed something deeper — do it, flag it as
deeper, propose it), or **Frontier** (a wall you could not close cleanly — name
it precisely). A clean frontier beats a forced green. Never manufacture one: no
per-test special-casing, no weakening a test so JS agrees.
