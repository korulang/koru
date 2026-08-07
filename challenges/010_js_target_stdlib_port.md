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

## READ THIS BEFORE ESTIMATING ANY TRANSFORM PORT (2026-08-06, regex)

`regex` shipped: **0/28 → 20/28**, zig-green 4/4, every `640_*` and `115_*` test
green. But almost none of that work was in `regex.kz`. **Three compiler walls
stood between a `|js` transform rendering and a backend that compiles**, and all
three block `store` and `kernel` exactly as they blocked regex:

1. **A `[transform]proc`-shaped event emitted no variant handlers at all.**
   `visitor_emitter.zig` short-circuits to a dedicated override for events
   implemented by `~[transform]proc` and returned before the variant loop, while
   `main.zig`'s dispatcher wrote `handler__js` branches anyway. The backend
   referenced a member nobody generated.
2. **The JS emitter spliced the transform's ZIG body as a runtime body**, putting
   `@import("ast")` into the output. `findJsProcIn` keyed on the tag alone.
3. **Top-level `.inline_code` was dropped in silence** — the declarations a
   transform appends beside the site it rewrites (regex's compiled matchers)
   never reached the JS file, while the dispatch calling them did.

Plus one that is not transform-specific and will hit any destructuring branch:
the effect-splice path bound `cont.binding` and skipped `emitDestructureBindings`,
so `| pat { l, w, h } |>` arrived with every field undefined.

All four are fixed. The load-bearing lesson for planning: **`print.blk|js`
working was not evidence that transform `|js` variants worked** — it is a plain
`~proc`, so it misses the override that broke everything else. The one existing
precedent was the one example that could not have caught the bug. Any store or
kernel estimate made before this landed was measuring the `.kz` half only.
Gardened as `frag-a-transform-proc-had-no-js-variant-machinery`.

The engine side is also further along than the module list suggests:
`compileToJs`, `compileSearchToJs` and `compileCapturesToJs` now exist in
`src/regex_engine.zig` beside their Zig kin, verified against the Zig engine as
oracle. Watch the word size — the Pike VM's `[4]u64` class mask transliterates
cleanly to JavaScript and is silently wrong there, because JS bitwise operators
are 32-bit; it is rendered `[8]u32`. See
`frag-a-host-word-size-is-part-of-the-rendering-contract`.

**What regex did NOT close**, and neither is regex's to fix: 3 AoC tests fail on
`PARSE003` (the one-variant-tag-union rule — `810_071` is red on the ZIG target
too, and was already red in the board at `fcd83850`), and 5 fail on `js_emitter`
`UnsupportedConstruct`. Those 8 are the honest residue of the 28.

## The ranking, and the one real trap

`fs:read-lines` is one proc in an 87-line file reached by 66 tests. `store:new`
is one of eight procs in 8,734 lines reached by 160. Sort by tests-per-line-read,
not by tests.

- **`kernel` SHIPPED (2026-08-06): 1/26 → 19/26.** Read the entry above on what
  actually blocks a transform port, then this:

  **It needed NO `|js` variant**, and that is the reusable finding. `init` is
  1391 lines with ~60 emission sites, of which **eight** differ between targets;
  the rest is AST analysis that is target-agnostic by construction. It branches
  on `CompilerEnv.lang` in one body, the shape `~capture` already settled
  (`control.kz:427`). **Ask what fraction of the OUTPUT differs, not how big the
  transform is** — mostly-different wants a variant, mostly-shared wants one
  body. `frag-a-transform-renders-two-languages-from-one-body`.

  Two non-spelling walls, both of which `store` will meet: the synthesized proc
  hardcoded `.target = "zig"` (that one string caused every non-mlir failure,
  as `NoJsProcBody`), and a transform-minted `host_line` is DROPPED on JS
  because that walk keys on the file extension carrying the line and a
  synthesized line lives in the user's `.k` — use `.inline_code`, which is
  emitted at top level on both targets.

  Residue, none of it kernel's lowering: 5 `|mlir` tests (refusing correctly by
  name), 1 fixture writing `@sqrt` into an op body, 1 trellis `KORU040`.

- **CORRECTION: this file said "all 30 kernel-blocked tests call it plain, no
  variant tag." Five do not.** `390_100/101/102/103/105` carry `|mlir` or
  `|mlir[gpu]` at the call site, so the portable population was 21, not 26. The
  claim was written while correcting the opposite error (the "never port"
  ruling) and overshot. The conclusion it supported still holds — kernel is
  portable, the GPU path is opt-in — but the count did not. `|mlir` appears in
  six files corpus-wide. The MLIR/GPU lowering is an **opt-in call-site variant**
  (`std/kernel:self|mlir { … }`, `|mlir[gpu]`, kernel.kz:355, 757-783) and the
  compiler already refuses unsupported variants loudly by name (KORU122,
  KORU123). The DEFAULT lowering generates struct layouts and loop code from a
  shape declaration, and nothing about that is Zig-specific. Kernel is a
  transform family exactly like store: it wants `|js` renderings, no `.kjs`, and
  `|mlir[gpu]` stays correctly refused as the one genuinely Zig-only surface.
  Worth ~29 tests behind `kernel:init` alone.

  *How the error happened, because the shape recurs:* a scout inferred "Zig-only"
  from the module's MLIR/GPU vocabulary and cited the Elm-shaped thesis in
  `JS_TARGET_SPIKE.md`. I propagated it into this file without opening
  `kernel.kz`. That is the second time in one day that document was treated as
  current state and was stale or misapplied — **grep density is not evidence of
  what a transform emits, and a design doc is a claim about the tree with a date
  on it.** Nobody caught it until the human asked "why is kernel on that list?".

  **RULED (Lars, 2026-08-06): kernel gets a pure JS lowering path.** Not a port
  of the GPU story — `|mlir[gpu]` is *"a little dubious on Zig too"* and whether
  it ever wants a WebGPU analogue is explicitly deferred, no rush. What kernel
  wants on JS is the ordinary lowering: shapes as typed arrays, pairwise and
  step as flat loops. That is the whole target.

  **Its emission surface is far smaller than the module.** `init` is 1391 lines
  but only ~60 of them are emission calls (`allocPrint` / `appendSlice` /
  writer); 109 sites are AST analysis and 18 are diagnostics. **The analysis is
  host-agnostic and stays Zig regardless of target** — it runs inside the
  compiler either way — so a second rendering touches the emission sites only.
  The text it emits is largely type declarations (`"x: f64, y: f64"`) that
  JavaScript does not need at all. Measure the emission surface, not the file:
  the same lesson that produced the wrong answer above gives a much better one
  here.

  Expect the `fmt:ln` shape problem — kernel's transforms are result-producing,
  so their JS renderings must emit STATEMENTS declaring a value, never a
  `break :__KORU_INLINE__` expression.
- **`interpreter` and `runtime` are a whole interpreter** — 4257 lines, 30 `|zig`
  procs, 340 uses of `std.`/allocators. 19 tests sit behind it. Genuinely out of
  scope until someone rules otherwise — and unlike kernel, that judgement is
  about size and substance, not about vocabulary.

## Store — the SINGLETON rung SHIPPED (2026-08-07): 0/19 → 16/19

Baseline **0/149**, measured: 136 `js-compile`, 9 `js-runtime`, 4 `js-timeout`.
`store:new` alone gates **148 of the 149**.

**CORRECTION: this file said "there is no incremental first green — nothing
passes until `new` produces a working JS store." There is one, and it is
cheap.** `store:new` generates TWO shapes and capacity selects between them.
The 111-line / 40-Zig-bearing measurement below is the CONTAINER. The SINGLETON
(`std/store:new(ui) { sel: 0[i64] }`, no `capacity:`) emits a plain struct and
four small procs, and its entire JS rendering is `let __koru_store_ui = { sel: 0
};` plus four `switch`es. Nineteen `690_STORE` tests declare only singleton
stores. Sixteen went green in one pass, the container untouched, and the Zig
emission is byte-identical for both shapes (diffed on four tests, singleton and
container). Gardened as the second section of
`frag-a-transform-renders-two-languages-from-one-body`: **the fraction that
differs belongs to the SHAPE, not to the transform** — one number for a
transform that generates two shapes is an average over two populations.

What the singleton rung actually bought, most of which the container inherits:

1. **`host_is_js` / `proc_target` read once** at the top of `new` (kernel's
   shape, `store.kz:539`). Every synthesized `ProcDecl` now takes
   `.target = proc_target`; there are **20** such sites, not the 19 recorded
   below, and the spelling is `allocator.dupe(u8, "zig")`, which is why a grep
   for `.target = "zig"` found none of them.
2. **The cell is `.inline_code` on JS and stays `.host_line` on Zig.** A
   `host_line` reaches the JS file only when the file it points at is a JS host
   facet (`js_emitter.zig:223`), and a synthesized line points at the user's
   `.k` — so the cell was dropped in silence while every accessor that reads it
   was emitted. `.inline_code` is written above `main_module`, where a JS `let`
   is exactly as reachable as a Zig `var` inside the struct.
3. **The branch-return convention differs in SHAPE, not syntax.** Zig returns a
   tagged union (`.{ .sel = value }`); JS returns `{ tag: "sel", sel: value }`
   (`js_emitter.zig:594`) — the payload key repeats the branch name. And
   `else => unreachable` has no JS twin: an unmodelled field index must throw,
   or the switch falls through returning `undefined` and the caller reads it as
   a branch object.
4. **The envelope mask is the word-size trap again.** `__store_envwrite` tests
   `mask & (1 << i)`; JS bitwise operators coerce to 32 bits, so the literal
   transliteration is silently wrong rather than a syntax error. Rendered as
   `Math.floor(field / 2**i) % 2 === 1`, exact to 2^53.

Residue of the 19, none of it singleton-shaped: `690_017` is `PARSE003` on
`?persist` (a branch-name rule, and the test already carries a `RULING`), and
`690_079`/`690_080` are one bug — `ReferenceError: koru_app is not defined`,
a store declared in an IMPORTED module. `storeEmitQualifier` mints
`koru_app.__store_…`, which is the Zig emitted-namespace path; the JS emitter
has no such namespace. That is the next singleton item and it is shared with
the container.

## Store — CONTAINER reconnaissance, 2026-08-06 (measured, nothing built yet)

**Store wants the VARIANT route, and kernel did not.** Apply the test kernel
produced — what fraction of the OUTPUT differs — and the two modules answer
oppositely, which is why they need opposite architectures:

| | emitted-text lines | Zig-bearing | verdict |
|---|---|---|---|
| `kernel` | ~60 sites | 8 differ | one body, `CompilerEnv.lang` |
| `store` | 111 | **40** | a second rendering |

Store's generated artifact is not a few seams — it is **a data-structure
implementation**: SoA row arrays, a handle table with generations, a free list,
brands, row↔slot maps, cycle-detection stacks, `@bitCast`/`@truncate`/`@intCast`
handle packing, and methods on `@This()`. So the commission's phase-2/phase-3
plan (templates, then `|template|js`) is the RIGHT one here. Do not carry
kernel's shortcut across; measure first, as kernel did.

It also hits both walls kernel hit, harder: **19 synthesized procs hardcode
`.target = "zig"`** (kernel had one, and that one string caused every failure),
and it mints **5 `host_line`s**, which are dropped on JS because that walk keys
on the file extension carrying the line — use `.inline_code`.

**THE HANDLE QUESTION IS SETTLED, and it is the good answer.** A handle packs
`slot | (brand << 24)` in the low 32 bits and the generation in the HIGH 32
(`store.kz:2626`). That has NO JavaScript transliteration — JS bitwise operators
are 32-bit and `x << 32` is a no-op, so the encoding cannot survive a literal
port (the `frag-a-host-word-size-is-part-of-the-rendering-contract` trap, in the
biggest module). But **no `expected.txt` in the corpus contains a raw handle
value** — handles are internal, the oracle cannot observe their encoding. So the
JS rendering is free to re-encode (a 53-bit-safe packing, or a slot/gen pair) and
does NOT need BigInt, which would have poisoned every arithmetic path a handle
touches. Verified by grep over the store fixtures' expected outputs, not assumed.

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

So the path, in order — **revised after the fs / fmt / string+list wave measured
two of its assumptions and found one wrong:**

1. **Do NOT extract `store.k` first.** The original plan opened with it. Three
   independent ports then landed with a bare `.kjs` sibling and a **byte-for-byte
   untouched `.kz`** — `fs`, `string`, `list`. Koru declarations in a `.kz` are
   host-agnostic and already visible to a sibling facet; only host LINES route by
   extension. `koru_std/args`' three-file shape is one legal layout, not the entry
   fee. This matters because extraction is the **expensive and dangerous half**:
   moving a `pub tor` out of a live module edits the file the Zig target compiles,
   which is exactly the edit that can regress a green board. A `.kjs` sibling is
   purely additive. See `frag-a-kz-is-already-the-contract-facet`.
2. **Convert the `allocPrint` assembly into templates**, Zig side only. Still the
   bulk, still a **total oracle**: behaviour must not change, so the board holding
   is a complete and ungameable check. No design decisions, no JS, fully
   incremental — one generator at a time.
3. **Add the `|template|js` renderings — and budget more than a translation.**
   The `declarations.kz` pattern transfers, but `fmt:ln` (0/7 → 6/7) found the
   non-obvious cost: *a second rendering is not a translation of the first,
   because the two emitters accept different SHAPES of product.* Two structural
   differences it hit, both of which store will hit: `break :__KORU_INLINE__
   <value>` has no JS spelling, so an inline body cannot be an EXPRESSION the
   emitter binds — it must be STATEMENTS declaring the value under the name the
   site reads; and the JS emitter splices an arm's body WITHOUT its bind, so the
   arm must declare its own name and hand off via a `__koru_continue_N` marker.
   Its warning, worth quoting: **"expect every result-PRODUCING transform to need
   this split; a purely streaming one like `print.blk|js` does not, which is why
   `print.blk|js` was easy and looked like the whole pattern."** Store's
   transforms are result-producing.

A rewrite is still a refactor with a perfect gate, and phase 1 just disappeared.
Phase 2 is parallel-safe per generator and does not contend with runtime ports.

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
