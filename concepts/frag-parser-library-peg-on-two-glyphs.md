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

**The one structural novelty a parser forces: named rules with branch bodies.**
Recursion requires rules referenced by name; alternatives must both parse and
deliver. Today those halves live apart — event declarations have named branches
but no bodies; flows have bodies but are anonymous. The fusion (spelling open:
`! rule <name>` region-arm vs decl-side vs subflow) is the single new construct
to design. Everything else is reuse.

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
