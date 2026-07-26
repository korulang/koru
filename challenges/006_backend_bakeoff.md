---
challenge: backend-bakeoff
kind: frame
status: standing
yields: one std/parser backend for a mainstream target language, passing conformance
family: toolchain
---

# Challenge 006 — Backend Bakeoff (parser-generator target languages)

> You ARE the contestant, not the assistant. Pick ONE **mainstream** target
> language that is **not already in the catalog**, author a `std/parser` backend
> that lowers a grammar to a standalone parser **in that language**, and prove it
> passes the shared conformance suite. Do **not** ask which language to pick —
> pick one, name it, ship. Do **not** ask if the target is "good enough" — if it's
> mainstream and not in the catalog, it counts. Your choice of language and your
> vocabulary-table decisions ARE the contribution; Lars judges *after* you ship,
> by running your emitted parser through a real compiler. Asking first negates the
> design.

This is a standing **generative frame**, not a backlog. There is no list of
languages to work down; each run re-derives "which mainstream target is missing"
from the live catalog and adds one. The valuable *output* — a target backend that
passes conformance — persists in `koru_std/parser.kz` and the conformance suite,
not a to-do. C is the reference implementation and the first catalog entry.

---

## ⏸️ HOLD ON NEW CHALLENGERS — the values are untyped (Lars, 2026-07-20)

**Status: this frame is PAUSED for new mainstream targets until the value model
is typed.** Not cancelled — paused, with the reason recorded so it un-pauses on a
concrete trigger.

The reason: cut-1 `std/parser` produces **untyped text spans**, not typed syntax
trees. Grounded in the codegen — every rule's result is `{ end: usize, val:
[]const u8 }` (`koru_std/parser.kz:586`), and a `-> expr` produce arm compiles to
`.val = (expr)` (line 320), so the produced value is constrained to a `[]const u8`
slice. On success the parser hands back the *accepted span*; there is no path yet
for a rule to build a typed node (an integer, a record, a variant, an AST struct).

So every backend this frame emits — C today, Zig, JS, Haskell tomorrow — is a
**fully-working span parser, not a typed-tree parser**. It correctly accepts,
rejects, backtracks, and reports furthest-failure errors; it does not construct a
typed value graph. Shipping a dozen native backends that all return spans
multiplies a *recognizer* across languages — the catalog's value compounds only
once the values are typed (one grammar → a dozen native parsers that all build the
**same typed tree**).

**The missing cut — the un-pause trigger:** typed captures / constructor
composition. The produce arm is *already* the constructor slot; it's just typed to
return text today. Lifting the value slot to per-rule (or grammar-declared) types,
so a produce arm can build a typed node, is the named next cut (the "constructor
composition" movement, 340_014-dependent). **When that lands, this frame
un-pauses** and new targets resume — now emitting typed-tree parsers worth having a
dozen of.

**What stays active meanwhile:** the **Zig** target (already in flight) is retained
— it's the emitter the Koru-self-parser probe needs regardless of the value cut.
And the driving goal moves to **using Koru's own grammar as the artifact**: capture
a self-contained slice of Koru's grammar as a `std/parser` grammar, generate a Zig
parser, diff it against the hand-rolled parser via the referee — and let the exact
walls it hits become the *measured* work list for the typed-value cut. Koru needs
to be parsed in more than one place; one grammar reused everywhere is the prize,
and it is worth more than breadth of span-only backends.

**The dream this serves:** one grammar, `koruc grammar.k parser:generate <lang>`
for a dozen mainstream languages, every emitted parser compiled by its own native
toolchain and producing identical answers. Koru as a *universal* parser generator
— the gateway drug. This challenge grows that catalog one language at a time.

---

## The surface — a target is a vocabulary table, not a new algorithm

The parsing *algorithm* is target-blind: recursive descent, DFA terminals, the
first-byte gate, common-head factoring, furthest-failure error tracking. All of it
is a *shape*. A backend re-expresses that shape in a new language, and the only
per-target decisions are a small **vocabulary table**:

- How do you spell a **slice** — fat pointer, `(ptr, len)`, a `string`, a `[]byte`?
- How do you return **"no match"** — a nullable, a `bool` + out-param + sentinel,
  a sum type / `Maybe` / `Result`, an exception?
- How do you spell a **labeled break** out of an ordered-choice block — a block
  break, a `goto`, a labeled loop, an early `return` from a helper?

Read the C backend in `koru_std/parser.kz` (the `generate` command handler and its
emitter) as the worked reference. Everything above the vocabulary table keeps its
shape. That is what lets a new target be *thin* — a vocabulary swap, not a compiler.

---

## ⚖️ MAINSTREAM ONLY — the target constraint (binding)

**Prioritize widely-used, mainstream languages.** The catalog is meant to make Koru
reachable to working engineers, so a target only counts if a real team might drop
the emitted parser into a real project. In-scope, roughly in priority order:

**Zig, JavaScript / TypeScript, Go, Rust, Python, Java, C#, Haskell, C++, Swift, Kotlin.**
(Lars named **Zig, JS, and Haskell** as especially wanted.)

**Out of scope: exotic / esoteric languages.** No Brainfuck, APL, J, Befunge,
Forth-golf, or one-off toys. Variance across *mainstream* targets is the value;
variance into esolangs is noise. If you're unsure whether a target is mainstream,
it isn't — pick one from the list above.

---

## The conformance contract — the done-gate AND the oracle

Every backend, in every language, must pass the **same cross-language differential
conformance suite**. From a shared set of `(grammar, input)` fixtures, the emitted
parser — **compiled by that language's own native toolchain** (`cc`, `zig`, `node`,
`go build`, `rustc`, `python`, `ghc`, …) — must produce **byte-identical canonical
output** to the oracle:

- Success: the accepted span (e.g. `OK: <text>`).
- Failure: `PARSE-ERROR <line>:<col> expected <X> found <Y>`, at the **furthest**
  position the parse reached (not byte zero).

**The oracle is the Koru-native parse.** The `641_*` regression tests define what
Koru's own `std/parser:parse` produces; the C backend already conforms to it. So
the law for every new language is: *reproduce, byte-for-byte, what Koru itself
produces on the shared fixtures.* Not "match C" — match **Koru**. (Arbiter's call,
set at creation 2026-07-20; change it here deliberately if ever, it's slow-clock.)

**This gate IS the missing test-shape.** The blog post "Generate a Standalone C
Parser" confessed the one honest gap: *"emit the `.c`, invoke a C compiler, run the
binary, diff its output — a test shape the harness has never had."* Backend Bakeoff's
done-gate **is** that harness. Building it once (shared fixtures + an
emit→native-compile→run→diff runner that auto-discovers each backend) is the
first-run infrastructure, and it doubles as the regression coverage the emit path
lacks. A backend with no conformance run is not a catalog entry — it's a claim.

---

## The variance rule — variance lives in the TARGET, never in the BEHAVIOR

Variance lives in **which mainstream language you target and how idiomatically you
spell its vocabulary table** — a Rust backend that returns `Result`, a JS backend
that returns `{ok, value}`, a Haskell backend over `Either`. That divergence is the
catalog's reach.

Variance does **NOT** live in *what the parser does*. Every backend must produce the
**identical canonical output** the oracle produces. A backend that parses `[42`
differently, or reports the error at a different offset, is a **bug**, not a variant.
"Idiomatic in the target language" is the freedom; "same answer as Koru" is the law.

---

## For contestants (the brief, sealed)

You are dropped into the koru repo. **Read the repo-root standards first** —
`CLAUDE.md` and `AGENTS.md` — they bind. Build koru once (`zig build`) so
`./zig-out/bin/koruc` is fresh, and confirm C works end-to-end (`koruc <grammar>.k
parser:generate c`, then `cc` + run) so you know the reference behavior you must
reproduce.

1. **Self-ground against the catalog.** List the target languages already covered
   (grep the `generate` command's target dispatch in `koru_std/parser.kz`). Pick ONE
   **mainstream** language **not** already there. Name it in one line.
2. **Read the C backend as the reference** — the emitter that turns the grammar's
   rules/terminals/choice/produce into C. Your job is the same shape, new vocabulary.
3. **Author the backend** — extend the `generate` command to emit your target. Keep
   the algorithm; swap only the vocabulary table (slice, no-match, labeled-break, the
   public API shape). Emit a runnable CLI behind the same "optional main" convention.
4. **Run conformance** — emit parsers for the shared fixtures, compile each with the
   target's native toolchain, run them, and **diff against the oracle** (Koru-native
   output). If the conformance harness doesn't exist yet, building it (fixtures +
   runner) is part of *this* run — say so, and build it minimally but real.
5. **Self-check the gates** (below) and hand up: the exact `koruc` command, the
   emitted source for one fixture, the native compile line, and the conformance diff.

Do NOT hand-tune the emitted output per fixture. Do NOT edit the oracle to match your
backend (conformance fraud). Everything you report is verifiable by re-running.

---

## For arbiters (Lars + Claude)

1. **Verify by running, not reading.** Emit the target from a fixture grammar,
   compile with the native toolchain yourself, run every fixture, diff against the
   Koru-native oracle. A green claim you didn't re-run is not verified.
2. **Taste-gate.** Is the emitted code *idiomatic* for the target (a Go engineer
   wouldn't wince), self-contained (no runtime of ours), and mainstream (a language a
   real team ships)? Idiomatic + conformant + mainstream = it appends to the catalog.
3. **Encode it.** A surviving backend lands in `koru_std/parser.kz`'s `generate`
   dispatch, plus its conformance fixtures in the suite. The catalog grows; the next
   run targets the next missing mainstream language.

**Never:** accept a backend whose output diverges from the oracle "because it's more
idiomatic" (the law is byte-identical); accept an esolang/toy target; let a sealed
contestant decide the oracle; edit the oracle to make a backend pass.

---

## Pass / value contract

A run has earned its keep when it produces **≥1 new mainstream-language backend** that
**passes the full conformance suite** — emitted by `parser:generate <lang>`, compiled
by that language's native toolchain, producing **byte-identical output to the
Koru-native oracle** on every shared fixture — and appends to the catalog. A backend
that emits but doesn't conform, or targets an exotic language, is not a pass. The
first run may spend itself building the conformance harness; that harness is itself a
first-class deliverable (it's the test-shape the emit path has never had).
