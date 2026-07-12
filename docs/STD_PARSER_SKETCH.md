# std/parser — grammar-surface sketch (design-walk artifact)

**Status:** PROPOSAL, 2026-07-12 walk. Nothing here is built; nothing here is
corpus unless explicitly cited. Anchors: `koru_std/regex.kz` (the shape to
echo), `340_014_constructor_named_targets_and_value` (the delivery arc),
the 2026-07-11 Redis-verbs walk (small vocabulary, no DSL), `docs/PARSER_PALETTE.md`
(different layer: compiler-internal callable parsers for template lowering —
related in spirit, not this library).

**Legend:** every form below is marked `CORPUS` (cited to a passing test or a
shipped decl) or `PROPOSAL` (invented for this walk, up for grabs).

---

## 1. The load-bearing insight: PEG is already in the glyphs

PEG has exactly two structural combinators:

- **Ordered choice** — try alternatives in order, first success wins, no
  reconsideration. This is *byte-for-byte* the semantics `std/regex:match`
  already ships: first matching pattern branch wins (`CORPUS`: 640_001,
  regex.kz:33 "first matching pattern wins").
- **Sequence** — parse A, then B with what's left, deliver both. This is the
  chain: `|>` steps that each consume input and bind results (`CORPUS` as a
  *glyph ruling*: tri-glyph — `|>` chains / `->` produces / `=>` constructs).

So the thesis: **a PEG grammar decomposes onto `|` and `|>` with no new
combinator forms.** Choice = branch dispatch. Sequence = the pipe chain.
Repetition/optionality live in the terminals (the regex layer already owns
`*`/`+`/`?`) or dissolve into rule recursion. The parser library invents
*vocabulary* (events), not *grammar shape* — same discipline as the
constructor's Redis resolution (verbs are events, not a DSL).

## 2. What is genuinely new: named rules with branch bodies

Recursion forces one structural novelty, and it's worth naming precisely:

1. Grammar rules must be **named** (recursion = reference by name; literal
   nesting can't spell `value → array → value`).
2. A rule's alternatives need **bodies** (each alternative both parses AND
   delivers something).

Today, the two halves live in different places: *event declarations* have
named branches but no branch bodies (`CORPUS`: regex.kz:58-60 declares
``| `*` *`` / `| ?no-match` — shapes only); *flows* have branch bodies but are
anonymous statements (`CORPUS`: 640_001 invocation site). A grammar rule needs
both at once. **That fusion is the ONE new construct std/parser asks of the
language.** Everything else below is reuse.

## 3. Movement one — the standalone surface (flagship: JSON)

The parse site echoes `std/regex:match` exactly — an ordinary module event,
qualified invocation, dispatch over branches:

```koru
~import std/parser
~import std/io

// CORPUS shape (640_001: invocation + pattern branches + fallback):
~std/parser:parse(input, grammar: json)          // PROPOSAL: grammar named by reference
| value v -> consume(v)                          // PROPOSAL: top-rule branch delivers the parse
| parse-error { line: usize, col: usize, expected: []const u8, found: []const u8 }
    |> std/io:eprint.ln("{{ line:d }}:{{ col:d }}: expected {{ expected:s }}, found {{ found:s }}")
```

The error contract is part of the surface from day one: `parse-error` carries
line/col (computed from byte offset at error time — the engine tracks offsets,
newline-counting happens once, on failure) plus expected/found. Precedent for
the shape: the dead `parser_generator.kz` sketch already declared
`| error { message, position }` (`CORPUS` as archaeology, not as law — that
file predates the regex engine and this work deletes it).

The grammar itself — the committed strawman, every line labeled:

```koru
// PROPOSAL: a grammar REGION — named rules as effect-style arms. Trellis
// polices the vocabulary inside the region (rule/expect/etc. and nothing
// else), per the 2026-07-11 ruling that regions get shape-laws, not DSLs.
~std/parser:grammar json
! rule value                                     // PROPOSAL: `! rule <name>` — named, referenceable
    | object o -> o                              // PROPOSAL: bare name = RULE REFERENCE
    | array a -> a
    | `"(?<s>[^"]*)"` { s } -> string(s)         // CORPUS terminal: backtick pattern + named-group
                                                 //   destructure (640_005), typed conversion at splice
    | `-?[0-9]+(\.[0-9]+)?` n -> number(n)       // CORPUS terminal: pattern + binding (640_003)
    | `true`  -> yes                             // CORPUS terminal: pattern, no binding (640_001 `_`)
    | `false` -> no
    | `null`  -> nil
! rule object
    | `\{` |> members(): m |> expect(`\}`) -> object(m)   // PROPOSAL: SEQUENCE = the chain;
                                                          //   `: m` bind-form is CORPUS (destructure-on-bind,
                                                          //   landed 32e4313f); `expect` = vocabulary event
    | `\{` |> expect(`\}`) -> empty-object
! rule members
    | member first |> more-members(first)        // recursion spells repetition (right-recursive)
! rule array
    | `\[` |> value(): v |> more-elements(v) -> array(...)
    | `\[` |> expect(`\]`) -> empty-array
```

Reading it back against the corpus:

- Terminal alternatives are **exactly regex match branches** — pattern
  branches with binding/destructure/typed-conversion (`CORPUS`: 640_001,
  640_003, 640_005). The regex engine is the terminal layer, unchanged.
- Sequencing inside an alternative is **exactly the chain** — each step
  consumes input and binds (`: m` bind-form `CORPUS` @32e4313f), `->` produces
  the alternative's result (bare-return `CORPUS`: tri-glyph ruling).
- The only novel *structure* is `! rule <name>` — the named-rule arm carrying
  a body of alternatives (§2's forced move). Its exact spelling (`! rule` vs
  a decl-side form vs subflow `#name`) is THE walk question. This strawman
  picks the region form because it keeps the whole grammar on one page,
  mirrors how `scan` uses `!` for its streaming arm (`CORPUS`: regex.kz:283-285),
  and gives Trellis a bounded region to police.

### PEG semantics, stated so we can reject them consciously

- Ordered choice with **no backtracking across a committed chain**: once an
  alternative's chain has consumed input, a later failure is a parse error at
  that position, not a silent retry of the next alternative. (PEG purists
  backtrack; committing early is what makes errors GOOD — "expected `}` at
  3:14" instead of "no alternative matched at byte 0". The `expect` vocabulary
  verb is the explicit commit point.) PROPOSAL — this is a real semantic
  choice; it trades some grammar flexibility for fantastic errors, which is
  doctrine (`feedback_fantastic_error_messages`).
- **Left recursion is rejected loudly at comptime** (cut 1): `! rule expr |
  expr ...` is a compile error naming the cycle, with the right-recursive or
  repetition rewrite in the message. Arithmetic precedence is expressible
  right-recursively (expr → term more-terms); packrat/left-rec support is a
  later engine upgrade under the same surface, exactly like Pike-VM →
  tagged-DFA was.

### Lexing: scannerless, with `scan` available

Cut 1 is **scannerless** — terminals are regex patterns applied at the current
position (the engine's anchored-match-at-offset entry point; `compileSearchToZig`
already does position-based matching, `CORPUS`: regex.kz scan loop). A separate
token stream via `std/regex:scan` composes *in front* when a grammar wants it,
but nothing requires it. Whitespace/comment skipping is a grammar-level
declaration (PROPOSAL: an annotation on the region, e.g. `~[skip(`[ \t\n]+`)]`),
not engine magic.

## 4. Movement two — constructor delivery (clearly marked: depends on 340_014)

Everything above delivers through bindings and `->` produces — flat payloads,
standalone-complete. When the constructor's next arc lands (named push
targets, recipe-as-value — `340_014`, honest-red), rule bodies gain the tree
face with ZERO new parser machinery, because pushes are just flow code inside
alternative bodies:

```koru
// PROPOSAL, and 340_014-dependent — the AST face:
~std/constructor(ast)
! construct |> std/parser:parse(input, grammar: json)
    // rule bodies push into NAMED cells; nested rules push RECIPES —
    // the tree is recipes-in-recipes (340_014: materialization recurses)
| constructor c |> std/constructor:construct(c): tree |> walk(tree)
```

One recipe, many materializations (340_014's words): the same parse can
materialize a comptime value (config baked at build), a generated type
(schema → struct via `construct:struct`), or emitted code (`std/types:emit`) —
which is the metacircular path: Koru's grammar in std/parser, producing the
compiler's own AST shape, diffed against `std/koru:parse` + serializer
(`CORPUS` referee: 220_007 pins the JSON dump today).

**Orthogonality contract (ruled on the walk):** std/parser MUST be complete
without the constructor (this section is additive), the constructor never
learns about parsing, and the registry serves both without knowing either.
Composition happens in user flow-space only.

## 5. What this displaces / renames

- `koru_std/parser_generator.kz` — pre-engine sketch (hardcoded `\d+`
  recognition, TODOs). Deleted by this work.
- `koru_std/parser.kz` (Koru-self-parse runtime wrapper) → renamed
  **`std/koru`** (`std/koru:parse`, `std/koru:dump`). 8 regression tests
  reference the old name (210_034/049, 220_002/006/007/008, 430_002, 520_003)
  — mechanical sweep. Ruled with Lars 2026-07-12.

## 6. Open questions for the walk (in priority order)

1. **The named-rule spelling** (§2/§3): `! rule <name>` region-arm vs
   decl-side rule events vs subflow `#name`. The structural need is settled
   (named + bodied); the spelling is not.
2. **Commit points / backtracking depth**: is chain-commit-on-consume the
   right default (errors-first), and is `expect` the right explicit verb?
3. **Repetition sugar**: is right-recursion enough on the page, or does the
   region want a `many`/`sep-by` vocabulary verb (still events, not grammar)?
4. **Skip/trivia declaration**: annotation on the region, or an ordinary rule
   with a marker?
5. **What a rule reference binds** in movement one (pre-constructor): the
   child's `->` produce, presumably — does that need a declared payload shape
   on the rule, or is it inferred?
