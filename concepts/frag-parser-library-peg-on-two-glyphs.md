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

**The one structural novelty a parser forces: named rules with branch bodies —
and the frontend already parses it (settled by building, 2026-07-12).** The
`! rule <name>` region form needs ZERO new syntax: `! rule value` parses as an
effect arm whose binding is the rule name, and its nested arms are the
alternatives (verified via --ast-canon). **Sequencing settled as NESTED arms**
(each level = "then consume") — this supersedes the sketch's `|>`-chain lean:
nesting is corpus-parseable today and dodges the bare-`value()` resolution
problem entirely; the chain form remains a possible later sugar, unruled.
Cut-1 semantics: pure PEG (sibling backtracking, whole-input consumption),
furthest-failure line/col errors, left recursion rejected at comptime by name.
Green: 641_001 (recursive flagship, v=42), 641_002 (error contract),
641_003 (left-recursion wall).

**Two toolchain gaps the arc surfaced and closed (the instrument working):**
1. The regex engine had NO escape support — no metachar was matchable
   literally in any pattern; std/parser's first terminal (`\[`) found it.
2. KORU100's transform-deferral only covered bindings whose own node invokes
   a transform — data-arms of a transform-ROOT flow (rule names) were flagged
   unused; no corpus flow had that shape until the grammar region.

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
