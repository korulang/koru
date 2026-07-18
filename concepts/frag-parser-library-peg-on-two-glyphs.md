---
type: belief
id: frag-parser-library-peg-on-two-glyphs
provenance: 2026-07-12 design walk with Lars — std/parser research session, sketch in docs/STD_PARSER_SKETCH.md
ts: 2026-07-12
---

# std/parser — PEG decomposes onto the two glyphs; one structural gap (belief)

A complete parser library needs no new grammar formalism: PEG's two structural
combinators are already Koru's two glyphs. **Ordered choice = branch dispatch**
(first matching branch wins — the exact semantics `std/regex:match` ships,
640_001) and **sequence = the chain** (`|>` steps consuming input, binding
results, `->` producing the alternative's value). Terminals are regex pattern
branches unchanged — `std/regex` is the terminal layer, and its own header
already anticipated this (`scan` self-describes as "the terminal layer of the
parser stack"). Repetition dissolves into terminals or rule recursion. The
library invents vocabulary (events), never grammar shape — the same resolution
as the constructor's Redis walk: verbs are events, not a DSL.

**The surface RATIFIED on the 2026-07-12 walk (supersedes this frag's earlier
nested-arm claim, which Lars ruled an invalid AST shape — see the doctrine
below): a grammar is a PROTOCOL, not a DSL.** Rules are effect arms binding a
CURSOR (`! value v`); each rule's body is ORDINARY CODE whose common picker
is the EXPLICIT `std/parser:match(v)` — branches must hang off a thing that
PICKS, never off a binding. The `->` arms of a match are **PATTERNED RETURNS**
(Lars's coinage): the input selects which value the rule produces — the
patterned-branch twin of the effect-resume arm, where the "SOMETHING that
brings the flow to an arm" is the match testing the input instead of a callee
choosing a resume. Sequence is the chain: `sub(<rule>): v` demands a
sub-rule, `lit("...")` consumes a literal (plain text, not regex). Because
the picker is explicit code it is NOT privileged — a rule body may be ANY
code (table dispatch, comptime-loaded data); the comptime codegen is a
PARTIAL EVALUATION of the static match-shape, and a non-static picker is a
loud wall, never a silent misparse. Cut-1 semantics: pure PEG backtracking,
whole-input consumption, furthest-failure line/col errors, comptime
left-recursion rejection. Green: 641_001/002/003.

**Doctrine earned the hard way (the nested-arm mistake): a transform may only
consume shapes the language has RULED, never shapes the parser merely
tolerates.** Cut-1's first sequencing spelling nested bodiless `|` arms under
`|` arms — parseable (flow_parser nests purely by indentation) but senseless:
a `|` continuation off NOTHING. Ruled invalid; the wall + MUST_FAIL pin make
the parser reject it. Effect arms keep exactly one aligned resume level
(210_134 pins flat, 400_133 pins the flow-site use).

**`[with]` RULED (Lars, same walk): scoped vocabulary resolution.** A
`[with]` annotation on a region invocation lets the resolver check the
invoked module for otherwise-UNRESOLVED events in the flow's immediate
lexical subtree — `match(v)`, `sub(value)`, `lit("]")` bare. Unresolved-only
(never shadows), multiple `[with]`s allowed, ambiguity forces an explicit
pick (the keyword-implementation precedent). Boundary doctrine: full
qualification stays the default everywhere; scoped resolution is the region
privilege (dense vocabulary + greppable region head + canon printer renders
qualified). Roadmap-red pin until the resolver feature lands.

**Duplicate-head ordered choice RATIFIED (Lars, 2026-07-17 — the JSON press):
same-named branches with different subtrees are a COMPTIME EXPRESSION TOOL.**
The PEG list idiom (`item "," rest | item`) and the long/short container forms
(`"{" members "}" | "{" "}"`) put two alternatives on one head, and cut-1 has
no epsilon rule to left-factor them away — duplicate heads are essential, not
convenient. The ruling generalizes past the parser: a transform may CONSUME
same-named branches as data, so branch ambiguity is a POST-NORMALIZATION
property. The frontend never judges when-clause exhaustiveness (KORU050/051);
judging happens after transforms, on what they left behind — and the shape
coverage walk stays out of transform-owned (`is_transformed_subtree`) arms
entirely, the same contract as the SHAPE002 skip. Consequence, per
[[frag-diagnostic-stage-follows-pass-home]]: the non-exhaustiveness wall
migrated stages (210_007), and the post-transform first responder learned to
say KORU050's teaching message for handled-only-behind-`when` instead of the
misleading "no continuation found". JSON-full is the instrument that forced
all of this out (641_004 flagship, 641_005 minimal pin) — and it made two
open designs concrete: threading `sub(ws)` between tokens is the loud
verbosity that argues for a trivia/skip declaration, and right-recursive
lists are the shape repetition sugar (`many`/`sep-by`) would collapse.

**Common-head FACTORING in the codegen (2026-07-18, the benchmark press):
consecutive same-head alternatives compile to head-parsed-ONCE + tails
tried in order.** Sound because cut-1 rule functions are DETERMINISTIC —
same position in, same result out — so PEG's backtracking reparse of a
shared head is guaranteed to reproduce the first parse and skipping it is
unobservable. This closed a SILENT EXPONENTIAL: `item sep rest | item`
reparsed every list's last element, compounding 2^depth on right-nested
input (SHOWN: a 111-byte depth-24 right-nested doc parsed at 9 passes/3s
vs 4.0M for its left-nested twin; after factoring both ~5M — the
benchmark repo's json-parse suite carries the cliff gate). The
no-silent-perf-degradation tenet is what made this a defect, not a
curiosity. Factoring does NOT preempt `sep-by`/packrat — deeper overlaps
(same head, diverging mid-chain) still backtrack; it makes the RATIFIED
duplicate-head shapes linear.

**Toolchain gaps the arc surfaced and closed (the instrument working):**
1. The regex engine had NO escape support — no metachar was matchable
   literally in any pattern; std/parser's first terminal (`\[`) found it.
2. KORU100's transform-deferral only covered bindings whose own node invokes
   a transform — data-arms of a transform-ROOT flow (rule names) were flagged
   unused; no corpus flow had that shape until the grammar region.
3. The emitter's inline-body effect bridge synthesized Handlers structs from
   transform-consumed arms and tried to alias wildcard decl branches
   (`const * = Handlers_0.*` — a pattern is not a name).
4. When-clause/coverage checkers still descended into transform-owned
   subtrees (the 2026-07-17 ruling above closed this).
5. SURFACED, NOT CLOSED: the Stage-A string lexer silently DROPS a whole
   statement when a literal contains `\\` immediately followed by `\"`
   (030_018 honest-red pin; suspect lexer.zig indexOfAtDepthZero, whose
   for-loop escape "skip" skips nothing — five hand-rolled in_string
   scanners is the bug class).

Rulings from the walk (Lars, 2026-07-12):
- **`std/parser` lives in koru_std**, not koru-libs — transforms must import
  `src/` engine modules (as regex.kz imports `regex_engine`), and comptime
  transforms cost nothing unused. koru-libs is the C-bindings home.
- **The self-parse wrapper vacates the name**: `koru_std/parser.kz` →
  `std/koru` (`std/koru:parse`, `std/koru:dump`). `parser_generator.kz` (dead
  pre-engine sketch) is deleted by this work.
- **Orthogonality is a design constraint**: std/parser, std/constructor, and
  the type registry are built in isolation, complete alone; composition happens
  only in user flow-space. The parser's tree face is the constructor's
  recipe-as-value arc ([[frag-std-store-design]] adjacent; pin 340_014) — a
  parse pushing recipes into recipes IS the AST, so tree delivery waits on no
  separate recursive-ADT feature.
- **Errors are surface, not afterthought**: `parse-error { line, col, expected,
  found }` from day one; chain-commit-on-consume (no PEG backtracking past a
  committed chain) is the lean because it makes errors precise — an explicit
  semantic trade, open for the walk.
- **North star held loosely**: the metacircular rewrite of Koru's own parser,
  refereed by diffing against `std/koru:parse` + serializer (220_007). An
  instrument, never the destination.
