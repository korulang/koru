# Parser Palette + Dumb Template Walker

**Status:** Design converged (2026-06-02), not yet built. Work-document for the
next build session. Supersedes the earlier framing in the memory note
`project_expression_lowering_layered_design` (which had the parse happening as a
Zig pre-pass; this document moves it to a callable, on-demand palette).

---

## 1. The problem (the frontier pin)

Opaque expression args — `~for`'s `iterable`, `~if`'s `cond`, both declared
`[]const u8` — are pasted **verbatim** into the target. Zig syntax like a range
`0..3` is valid Zig but breaks JS: `for (const x of 0..3)` is a Node SyntaxError.

Pinned by `tests/regression/100_MODULE_SYSTEM/140_FILE_LAYOUT/140_014_for_template_cross_target`
(RED frontier). `~if` already lands honestly on JS; `~for` is narrowed to exactly
the range→JS-iterable gap.

The verbatim-paste fast path is *correct and fast for Zig*. The question is how
the JS path (and any future target) understands enough of the expression to emit
something legal — **without turning the template engine into a parser**.

## 2. The shape of the answer

Two parts, deliberately split by where intelligence lives:

1. **A relatively-dumb template engine** that can *walk* an already-parsed tree:
   dispatch on node kind, descend into children, iterate child collections, emit
   text. It never parses. It is a total tree-walker (see §6).

2. **A wide, open palette of callable parsers** — `parse_expr` (Zig-subset),
   `parse_json`, and whatever else — each a real Zig parser with real located
   diagnostics, each turning opaque bytes into a tree. The template *calls* these
   on demand; it does not implement them.

This keeps faith with the earlier "template-as-parser is rejected" decision:
parsing is `string → tree` and stays in Zig; walking is `tree → output` and is
what the template does. Opposite directions; the rejection only ever applied to
the first.

It is also the existing Koru thesis reaching the emit backend: *smartness lives
in opaque-payload-consuming Zig; the dumb surface only orchestrates.* Source
blocks, opaque expression params, "you are the compiler" — all the same sentence,
now applied to code generation.

### Worked intuition

```liquid
{# a Source block of JSON, or an Expression, arrives opaque #}
{% const tree = parse_json(source) %}
{% case tree.kind %}
  {% when "object" %}{ {% for field in tree.children %} ... {% endfor %} }
  {% when "array"  %}[ {% for el in tree.children %}{% render "emit", node: el %}{% endfor %} ]
  {% when "string" %}"{{ tree.fields.value | escape_js }}"
  {% when "number" %}{{ tree.fields.value }}
{% endcase %}
```

The `~for` range case becomes a *special case* of this general mechanism:
`{% const e = parse_expr(iterable) %}`, branch on `e.fields.is_range`, emit either
a counting loop header or a `for…of`. No bespoke range machinery.

## 3. The universal node ADT (the spine)

Every parser converges on **one** generic node representation, and the walker
consumes only that. This is the load-bearing decision — the template is dumb
*because* every parser hands it the identical protocol.

```
WalkNode {
  kind:     []const u8                 // dispatch tag: "binary", "object", "number"…
  fields:   map<[]const u8 → Value>    // named scalar/handle slots: op, value, is_range
  children: [WalkNode...]              // ordered sub-nodes
}
```

- JSON object → `kind:"object"`, named `children` (or fields carrying keys).
- JSON array  → `kind:"array"`, ordered `children`.
- `a * b + c` → `kind:"binary"`, `fields{op:"+"}`, `children:[<a*b>, <c>]`.

**Three consumers, one type:**

- src parsers **produce** `WalkNode`,
- the `$std/parsers` Koru events **carry** it as their `| ok` payload,
- `liquid.zig` **consumes** it as a new `Value` variant.

Open sub-decision: define `WalkNode` as one shared Zig struct that liquid imports
(less projection, couples liquid to the type) vs. liquid defines its own generic
record `Value` variant and the filter layer projects native trees into it (keeps
liquid Oya-generic). Lean: shared `WalkNode` for the first cut; revisit if liquid
genericity matters for Oya.

## 4. `const` binding (parse-once, walk-many)

```liquid
{% const tree = parse_json(source) %}
```

- **`const`, not Liquid's `assign`.** Bind-once is the totality firewall made
  syntactic. `assign` is mutable (`{% assign acc = acc | append: x %}`), the door
  to accumulator-driven control flow. `const` forbids rebinding. Nothing is lost:
  a tree-walker accumulates by *emitting* (the output stream is the accumulator),
  not by mutating a variable.
- **Scoping is free.** A `const` is `ctx.put(name, value)` into the current liquid
  `Context`; lexical scope falls out of the existing `parent`/`scope` chain
  (`liquid.zig:67-87`), and loop bodies already get a fresh `loop_ctx` that is
  deinit'd per iteration (`liquid.zig:237`) — so a `const` in a `{% for %}` body
  dies with the block, like a real `const`.

### The one rule that keeps `const` from rotting into a language

> **The `const` RHS is a single call or a single value — never an expression.**

- ✅ `{% const tree = parse_json(source) %}` — a call
- ✅ `{% const root = tree %}` — a reference
- ❌ `{% const x = a + b * c %}` — arithmetic = the language-creep we call parsers
  to avoid.

Navigation (`tree.fields.value`, `node.children`) happens at the **use site**
(`{{ }}`, `{% case %}`, `{% for %}`), never in the binding. This is the highest-
risk primitive in the whole design; hold this line and `const` stays a binding.

## 5. Two front doors over one parser

The bottom is always a Zig fn (the src parser module). We put two front doors on
it; the template's is a thin Zig filter, the end-user's is a Koru event.

### End-user door — a Koru event in `koru_std/parsers.kz`

Mirrors the verified `check_structure` pattern (`compiler.kz:1305-1307` event +
`:1911` `~proc|zig`):

```koru
~pub event parse_json { src: []const u8 }
| ok WalkNode
| err { message: []const u8 }

~proc parse_json|zig {
    const json_parser = @import("json_parser");
    // ... produce WalkNode or report into the | err branch ...
}
```

End-user Koru code then gets the whole palette first-class:

```koru
~parse_json(src: payload)
| ok tree |> walk(node: tree)
| err m   |> report(message: m)
```

This is the unlock: **every parser added to `$std/parsers` grows the end-user
language surface for free.**

### Template door — a registered filter in `template_processor`

`template_processor.zig` is `src/` Zig (Stage-A/B). It calls the **same src
parser directly** — NOT the lowered event — because a Koru event lowers into
`backend_output_emitted.zig` (Stage-C, generated *from* `compiler.kz`, which
depends *on* `src/`), so `src → emitted` is a backwards dependency that won't
wire. So:

1. Add the import in `compiler.kz` build wiring (next to `:402-406`):
   `template_processor_module.addImport("expression_parser", expression_parser_module);`
   (and likewise for any new parser module).
2. Give `liquid` a filter/callback registry (it has none today — it is pure
   substitution). `template_processor` registers `parse_expr` / `parse_json` /
   `emit_js` / `emit_zig`, backed by the src parsers + tree emitters.

### Errors on both doors

- Event door: the `| err { message }` branch, same path as `check_structure`
  appends to `ctx.errors`.
- Template door: liquid's existing `{% comp error %} → error.CompError` channel
  (`liquid.zig:100-112`, `:169-179`) hands the message back to the caller that
  knows the source location → a real located Koru diagnostic, never a silent
  mispaste. A parse failure inside a template is loud and located.

## 6. The totality firewall ("dumb, not a language")

The template stays a **total, structurally-recursive tree-walker**. Every template
provably terminates, which is the precise definition of "not a fully-fledged
language." Guaranteed by two conditions:

1. **`for` only iterates finite child collections** — Liquid has no `while`, so
   this is free.
2. **`render` only recurses on strict sub-nodes** of the current node — the only
   footgun (`{% render "self", node: node %}` loops forever). Make it a hard
   engine rule ("render target must be a strict sub-node") or a depth cap.

All language-power lives in the Zig parser palette (arbitrarily smart, real
grammars). The template cannot be a language: no parsing, no unbounded loops.

### Power levels (where we are / where we stop)

- **L0 (today):** interpolate + truthy-`if` + `for`-over-array + dotted access.
- **L1:** + node-tag dispatch (`{% case %}`) + structured `WalkNode` Value.
- **L2:** + recursive `{% render %}` on sub-nodes → **arbitrary AST walks**
  (catamorphism). Total if recursion decreases.
- **L3 (target):** + `{% const %}` + args passed *down* through `render`
  (inherited attributes) → full **attribute-grammar evaluator**, still total.
- **L4 (the cliff — refused):** `while`, recursion on synthesized values,
  unbounded counters → Turing-complete = a language.

**Target is L3, proven by our own code:** `expressionToString`
(`expression_parser.zig:709-715`) wraps *every* binary in `(...)` to dodge operator
precedence. A real emitter that produces `a * b + c` (not `((a*b)+c)`) must pass
the parent's precedence *down* — an inherited attribute = `render` with args = L3.
Indentation is the same story. So L3 is required for clean output, not a luxury.

## 7. Thesis payoff

1. **Subsumes the hand-written emitters.** Re-express `expressionToString` /
   `emitter_helpers` tree→Zig walks AND the tree→JS walk as walker templates over
   the same `WalkNode`. The Zig backend becomes a template.
2. **Free differential oracle.** Run the walker-as-Zig-emitter over a corpus,
   assert byte-match against the existing `emitter_helpers` output.
3. **Userland DSLs get a backend for free.** Source blocks (opaque payloads) get
   walked by *userland* walker templates with the same primitives. The template
   engine becomes the universal emit substrate for any "you are the compiler" DSL.

## 8. Build increments

LANDED (2026-06-02, all green under `zig build test`; the engine decision was
the projected option — liquid owns a generic `record` `Value`, parsers project
into it, §3/§10):

1. ✅ **`liquid.zig` walker primitives** — `Value.record` node variant; dotted
   record access in `Context.get` (`node.left.op`); `{% case node.kind %}{% when
   "…" %}{% else %}{% endcase %}` dispatch; `{% render "name", var: node %}`
   recursive sub-templates via a `TemplateRegistry`; `{% const x = f(a) %}` +
   `FilterRegistry` (the call evaluator, RHS rule from §4 enforced); lexical
   scoping via a lazy locals overlay; for-loop binds the item as a record so it
   can be passed whole to `render`. Bundled behind `RenderEnv`. Unit tests
   include the recursive `1 + 2 * 3` walk.
2. ✅ **`json_parser.zig`** (new): real recursive-descent JSON → liquid record
   tree; `parse_json` filter adapter. Tests parse + walk real JSON (object +
   nested array via a recursive `emit` template).
3. ✅ **`build.zig`**: `json_parser_module` + `liquid`/`json_parser` test
   artifacts wired into `test_step` (they were NOT in the suite before).

4. ✅ **Simplified range path → `140_014` GREEN (the capstone).** Decision
   (Lars, 2026-06-02): ship *simplified ranges for JS now*, defer the full
   Zig-subset translator. Landed: a `parse_range` filter in
   `template_processor.zig` (`"0..N"` → record `{is_range, lo, hi}`, top-level
   `..` only — a slice `buf[0..n]` is not a range); the per-call render now goes
   through `renderWithEnv` with that filter; `for|template|js` in `control.kz`
   branches `{% const r = parse_range(iterable) %}{% if r.is_range %}` → JS
   counting loop `for (let i = lo; i < hi; i++)` (perf-correct, not `Array.from`),
   else `for…of` verbatim. `140_014` passes on BOTH targets (JS equivalence
   green). This *uses* the const+filter+walker infra above — only the range
   classifier itself is the throwaway-simple bit.

DEFERRED (the corpus survey — capture/kernel — shows real complex Zig in
expression/Source positions: `&[_]i32{…}`, `@as`, `@divTrunc`, field-arithmetic,
kernel DSL `bodies.vel -= d*mag*bodies.other.mass`. All Zig-only TODAY, so not
blocking. The forward direction Lars articulated: a **Koru-native portable way
to express these** — a small DSL that loads into BOTH Zig and JS — possibly as
part of the language. Until then, JS `~for` supports ranges + JS-shaped iterables):

5. **Full Zig-subset expression translator** — EXTEND the existing
   `expression_parser.zig` (already does binary/unary/field/index/call/`@builtin`/
   conditional/literals) with `..` ranges + array literals (`&[_]T{…}`); add a
   tree→JS emitter with the ~6 lowering rules (`@as`→erase, `@divTrunc`→`Math.trunc`,
   `&[_]T{…}`→`[…]`, range→counting loop). Mind the `ast` exhaustive-switch ripple
   (2 new variants).
6. **ast.Expression → liquid record projection**, so `parse_expr` returns a
   walkable node like `json_parser` does → richer template walks.
7. **`koru_std/parsers.kz`** (new, `~[comptime]`): event wrappers (end-user
   door); import from `compiler.kz` (mirror `:3-5`).
8. **Kernel/capture → JS**: make the userland `[transform]` target-aware (emit
   JS loops keyed on build lang — same `|js`/`|zig` split) + run stray
   `@builtins` through the translator. Kernel's DSL arithmetic is ~1:1 portable.
9. **L3**: inherited-attribute precedence — pass parent precedence down through
   `render` args so the expr walker emits minimal parens (currently always-flat).

## 9. Test strategy — unit tests first

`liquid.zig` already has unit tests (`:343-424`). Develop the entire walker in
isolation, in `zig build test`, against synthetic `WalkNode`s — millisecond loop,
no compiler round-trip:

> build `binary(+, lit 1, binary(*, lit 2, lit 3))` → run walker template →
> assert `"1 + 2 * 3"`.

Pin each primitive (`const`, `case`, `render`, `for`, each filter) as its own unit
test. THEN wire into `template_processor` and let `140_014` go green as the
integration capstone.

## 10.5 Current expression-handling state — THE LIMBO (mapped 2026-06-02)

Status map for a future design session (design deferred — this is just *where we
are*). We are stuck between two models and have committed to neither. There are
really **four** representations in play, split by the metacircular boundary:

**Model A — opaque Zig text, pasted verbatim.** Dominant. `arg.value`,
`Field.expression_str`, branch-constructor `plain_value`, proc bodies, host
lines, Source blocks. Emitted unchanged (`emitter_helpers.zig` ~1769/1789/3712).
The *inside* of an expression (`acc.sum + item`) is never normalized — it's Zig,
so it breaks on JS.

**Model B — Koru's OWN format, translated to Zig.** We already have this: the
`name: value` field syntax (branch constructors, struct inits) → Zig
`.name = value`. But it's done by TWO bespoke transforms from TEXT, in different
stages: `union_codegen.zig:100-138` (Stage A) and `emitter_helpers.emitStructLiteral`
(~1180-1280, Stage C). The expression grammar in `expression_parser.zig` is also
Koru-flavored (`and`/`or`/`++`, `if(c) t else e`), not raw Zig.

**Model C — parsed tree (`ast.Expression`).** Real and LIVE in Stage A:
`expression_parser.zig` → `ast.Expression` → `expression_codegen.zig`, consumed by
`union_codegen.zig:187` (when-clause `condition_expr`) and `tap_codegen.zig:314`.
NOT dead code. BUT the tree is **dropped at the serialization boundary**:
`ast_serializer.zig:896` doesn't serialize `parsed_expression`; `:1094` writes
`.condition_expr = null`. So Stage C (the main metacircular pipeline) never sees a
tree — only text.

**Model D — ad-hoc string surgery.** Each context patches text independently:
`parse_range` (added today), tap split on `->`, kernel `k.other.X`→`ptr[j].X`
(`kernel.kz:1119`), `emitValueWithBindingSubstitution`. Accreting, uncoordinated.

**The starkest limbo signature:** for branch constructors, the parser
(`parser.zig:6240-6279`) parses the field value into a tree, USES it to validate
purity (`containsFunctionCall` → PARSE003), then `defer expr.deinit()` **discards
the tree** and stores `.expression = null, .expression_str = <text>`. We parse,
judge, throw away, re-paste. `union_codegen`'s tree-path for fields is therefore
dead (always falls to `expression_str`).

**Bottom line / the undecided question:** we have BOTH a Koru expression format
(the `name:value` surface + the `expression_parser` grammar) AND verbatim-Zig
paste, used inconsistently, with the one structured representation (Model C)
killed at the metacircular boundary — so nothing downstream can rely on it, and
every new target need (JS) gets another Model-D text-mangle. The design-session
decision: commit to a Koru expression IR that **survives serialization** and
emits per-target (the [[project_expression_lowering_layered_design]] /
portable-DSL direction), or commit to verbatim-Zig and accept Zig-only
expressions. Today we pay for both and bank neither.

## 11. Open questions

- `WalkNode` shared Zig struct vs. liquid-owned generic record + projection (§3).
- Strict-sub-node `render` guard: hard engine rule vs. depth cap (§6).
- Leaf emit filters: explicit `emit_js`/`emit_zig` per template variant vs. a
  lang-implicit `emit` reading build-lang. Lean: explicit (each `|template|js`
  body already knows its target).
- `const` RHS: confirm "call or value only," navigation at use-site only (§4).

## Verified anchors

- `compiler.kz:1` `~[comptime]`; `:3-5` transitive stdlib imports (the hardcode
  pattern to mirror).
- `compiler.kz:1305-1307` event w/ `| ok`/`| failed` branches; `:1911`
  `~proc check_structure|zig` `@import`-ing a Zig lib (event-wraps-Zig pattern).
- `main.zig:6425-6441` auto-inject `~import "$std/compiler"`.
- `compiler.kz:402-406` `template_processor` build imports (where to add parsers).
- `liquid.zig`: no filters (`:142-158`), `Value = {string,boolean,array}`,
  Context `parent`/`scope` (`:42-88`), `comp error` channel (`:100-112`,`:169-179`),
  per-iteration `loop_ctx` (`:237`).
- `expression_parser.zig`: tree builder + lone `expressionToString` serializer
  (always-parenthesizes binaries, `:709-715`), no `..`.
- `template_processor.zig`: passive, pre-computes all Context vars, renders via
  `liquid.renderCollectCompError` (`:222`,`:561`).
