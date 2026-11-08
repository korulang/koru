# Block editor — coverage table and gap analysis

Measured against tree `09b5af7` (main), 2026-11-08. Sources: `src/ast.zig`,
`src/parser.zig`, `src/ast_printer.zig`, `src/ast_json.zig`,
`scripts/roundtrip_harness.sh` (run facet-corrected this session),
`koru_std/control.capture.kz`, `koru_std/cell.kz`, Scratch block taxonomy
(hat / stack / reporter / boolean / C / cap; ~125 blocks, 10 categories,
flat id-map serialization with `next`/`parent` links, no dynamic
`branchCount` in the extension spec).

Purpose: the field-by-field map from Koru's AST to a Scratch-style visual
editor — what becomes a block, what becomes a socket, what becomes a
property card, what stays text. Doubles as the seed of a design document
if an experimental editor is ever commissioned.

## The core claim

Koru's executable layer IS a block tree — more regular than Scratch's.
A `Flow` is one `Invocation` plus `Continuation`s; every `Continuation`
carries a branch name, optional binding/destructure, optional `when`
condition, exactly one child `Node`, and nested continuations for that
node's own arms (`src/ast.zig:1858`). The parser produces only **seven**
`Node` kinds: `invocation`, `label_apply`, `label_with_invocation`,
`label_jump`, `terminal`, `branch_constructor`, `expression`. Everything
else (`foreach`, `conditional`, `switch_result`, `assignment`,
`conditional_block`, `metatype_binding`, `inline_code`) is
transform-produced and never appears in source — and never needs a block
shape, because the editor operates on the **pre-transform** AST (the same
tree `--print` serializes: post-parse, before merging and transforms).

Vocabulary used below for visual treatments:

- **stack block** — vertical connector, Scratch stack/C-block analog
- **arm block** — container whose named substacks are generated from the
  callee's `EventDecl.branches` (the generative piece Scratch lacks)
- **reporter / boolean** — expression socket (oval / hex)
- **hat** — script/decl starter
- **cap** — terminal `_`
- **property card** — non-spatial editor for types, annotations, phantoms
- **text socket** — free-text field inside a block (Scratch does this too)
- **opaque card** — verbatim host/code region, shown not edited
- **fragment socket** — a socket whose contents are a Koru program
  fragment (`Expression`/`Source` params) the callee's transform
  re-parses — distinct from a value socket

## Design constraints (commissioned 2026-11-08)

1. **Source text stays canonical and editable.** The editor's data
   (AST JSON) is a derived projection — never the sole representation.
   A file the editor cannot also show as text is a file the editor has
   broken. This rules out block-only persistence by construction.
2. **Two-way sync is the open question, not a solved substrate.**
   Text→AST→text is measured stable (§10); block-edit→AST→text is
   stable *if* edits go through the tree. What is NOT yet established:
   whether this artifact is a teaching tool (where canonical-print
   normalization — comments aside — is acceptable) or a real editor
   (which needs edit-fidelity: untouched regions must survive
   byte-identical). That ruling decides how much of §10's gap list
   matters. Do not assume bidirectional fidelity is free.
3. **Decoupled from the SQLite-source discussion.** Source-in-SQLite
   was raised separately for swarm-based coding. The editor's data
   model treats AST JSON as interchange and source text as canonical;
   nothing here should couple to a storage backend until that ruling
   lands.

## 1. Program / file level

| Koru construct | AST | Scratch analogue | Visual treatment | Notes |
|---|---|---|---|---|
| File / module | `Program.items` | Project + sprite list | Project navigator; one canvas per file | Multi-file is standard IDE work, not a Scratch problem |
| `import std/io` | `import_decl` | (none — Scratch has one project) | Palette/namespace section per module | `local_name` gives the dotted namespace |
| `part impl` | `PartDecl` | (none) | File-group badge on the module | Consumed by loader; parts are flat sibling files |
| `// comment` (`.k`) | **dropped at parse** (`parser.zig:1425`) | Scratch comment = stack block | Needs a comment item or trivia attachment — commissioned separately | `.kz`/`.kjs`/`.kmd` comments DO survive as `host_line` items, unclassified |
| host bytes / Zig code | `host_line` | (none) | Opaque card, verbatim | Also carries `.kz` comments mixed with real code |
| `~[...]` module annotations | `Program.module_annotations` | (none) | Property card on the file | e.g. `[comptime]`/`[runtime]` |

## 2. Flow core — the block layer

| Koru construct | AST | Scratch analogue | Visual treatment | Notes |
|---|---|---|---|---|
| `event(args): bind \|> next(...)` | `Flow` → `Invocation` + `Continuation` chain | Stack of blocks; `\|>` is "next" | **stack block** per invocation; the `: bind` is a label field on the block's output socket | The chain IS the script — no separate "script" wrapper needed |
| `\| branch_name payload \|> body` | `Continuation{branch, binding, node, continuations}` | C-block arm / custom-block output | **arm block**: one named sub-stack per declared branch | Arms are generated from `EventDecl.branches` — generative, not palette |
| `\| ok n when n == 0 => quit` | `Continuation.condition` (+`condition_expr`) | "if" guard inside an arm | Guard badge on the arm block; condition is a **boolean reporter** socket | `when` filters which payloads enter the arm |
| `_` terminal | `Node.terminal` | Cap block / "stop this script" | **cap block** | Every flow can end in `_`; `\| quit \|> _` is the exit |
| `#label event(...)` / `@label(...)` | `label_with_invocation` / `label_jump` / `label_apply` / `LabelDecl` | (none — Scratch has no goto) | Label node + jump node, or desugar to repeat-wrapper | Rare in corpus; candidate for "advanced" tier |
| `=> branch { fields }` / `=> expr` / `-> expr` | `Node.branch_constructor` | (none — Scratch blocks can't return tagged values) | **reporter block** returning a named outcome | How subflow impls produce outcomes; `->` is bare-return sugar |
| bare expression in body position | `Node.expression` (raw string) | Reporter value dropped on the stack | Text/expression node | Rare; body-position expr lowers per context |

## 3. Node kinds — complete parser-produced set

Only these seven exist at source level. `foreach`, `conditional`,
`switch_result`, `assignment`, `conditional_block`, `metatype_binding`,
`inline_code` are transform output — excluded by design (the editor never
sees them; `--print` refuses them as unprintable).

| Node | Surface | Treatment |
|---|---|---|
| `invocation` | `path(args): bind \|> ...` | stack block; args are sockets |
| `terminal` | `_` | cap block |
| `branch_constructor` | `=> name {…}` / `=> x` / `-> x` | reporter block (outcome value) |
| `expression` | bare expr at body position | expression node (text or reporter nest) |
| `label_apply` / `label_with_invocation` / `label_jump` | `#lbl`, `@lbl(...)` | label/jump nodes — advanced tier |

## 4. Expressions

| Construct | AST | Scratch analogue | Treatment | Notes |
|---|---|---|---|---|
| literal / ident / binary / unary / field_access / grouped / call / index / conditional | `ExprNode` union | Reporter + boolean blocks, nested sockets | **reporter/boolean blocks** with nested sockets | Full tree exists — but see the string gap below |
| arg value `f(x: 1 + 2)` | `Arg.value` string + optional `parsed_expression` | Number/string input socket | Text socket by default; reporter nest where `parsed_expression` exists | **Gap**: most flow positions store expressions as raw strings (`condition`, `iterable`, `Arg.value`, `Node.expression`, `switch_result.expression`) — parsed lazily, not guaranteed present |
| `when` condition | `Continuation.condition` + `condition_expr` | Boolean socket on an if-block | Boolean reporter socket | `condition_expr` parsed on demand — the pattern to generalize |
| `for(0..n)` range | `Expression` param → `Arg.expression_value` (`CapturedExpression`: text+scope) | "repeat \[n\]" C-block | Range socket (two number sockets or text) | Scope capture is comptime machinery — invisible in the editor |
| `capture { total: 0 }` seed | `Arg.source_value` (`Source`: text+scope) | (none) | **Source block card** — the `{...}` interior is a mini-surface | Same for any `Source`-typed param |
| `{{ x:d }}` interpolation | inside string literals | (none — Scratch has no typed interpolation) | Text inside string socket | Stays text; it's string content, not AST |

## 5. Declarations

| Construct | AST | Scratch analogue | Treatment | Notes |
|---|---|---|---|---|
| `tor name { ins } -> T` / `\| branch payload` | `EventDecl` | Custom-block definition (`define`) | **Hat/definition card**: name, input fields, declared outcome arms | Arms shown as the block's output vocabulary — this is what generates arm blocks at call sites |
| `tor impl` (`greet -> ...`, `run = step()` arms) | `Flow.impl_of`/`impl_variant`/`is_impl`, `ImmediateImpl` | "when I receive" hat + custom-block body | Hat block attached to the tor it implements | `ImmediateImpl` = constant/stub impl — a value card |
| `proc name\|zig { ... }` | `ProcDecl` (`body: Source`, opaque) | (none — Scratch has no host escape hatch) | **Opaque card** with host syntax highlighting | `.kz` only; `inline_flows` extracted from body stay visible |
| `host_type_decl` / host struct | `HostTypeDecl` | (none) | Property/type card | Structured `module/path:Type` fields |
| `label_decl` | `LabelDecl{name, continuations}` | (none) | Label hat + body stack | `#repl` loops in dice.k are the canonical example |
| `event_tap` | `EventTap{source?, dest?, is_input_tap}` | (none — closest is broadcast receive, but wildcard) | **Aspect panel**, NOT a block | User ruling: taps are aspect-oriented instrumentation, not first-class programming surface |
| annotations `[pure]`/`[mutable]`/`[depends_on]`/`[keyword]` etc. | `annotations` on decls/branches/bindings/invocations | (none) | Property card / badge on the block | `[keyword]` marks the stdlib convenience tors (`for`, `if`, `capture`) — the editor can recognize them but doesn't need to special-case |
| `is_public`, `target` (`\|gpu`, `\|js`) | decl fields | (none) | Property card | Variant selector `\|variant` on invocations likewise |

## 6. The obligation / type vocabulary — the hard tier

These have NO Scratch analogue. Each needs either a new shape or a
property card; this is where the design work actually lives.

| Construct | AST | Scratch analogue | Treatment | Notes |
|---|---|---|---|---|
| phantom/obligation types `*T<active!>`, `?`, `?!` | `Field.phantom`, `Branch.is_optional`/`is_panic`, `return_phantom`, `resume_phantom` | (none — Scratch is untyped) | Property card on the field/arm badge | `?` = optional arm, `?!` = panic-if-unhandled — visual: arm badge variant |
| effect branch `! ask i32 -> U` | `Branch.kind=.effect`, `resume_type`, `resume_arms` | (none — the complexity cliff) | **Effect arm block**: payload-out socket + resume-in socket; multi-arm resume = arm picker | The one construct with zero Scratch coverage. `for`'s `! each` is the gentle intro: it feeds items, asks nothing |
| multi-arm resume `! ask i32 \| halved i32 \| timeout` | `ResumeArm[]` | (none) | Sub-arm list on the effect block | Handler constructs which resume arm fires |
| destructure `\| found { name, x: pos.x }` | `Continuation.destructure` (`DestructureField`: name/path/type_text/sub/annotations) | (none — Scratch has no pattern matching) | Field-list card on the arm's binding socket | Named groups `{...}` vs bare projection `{...}` — `destructure_named` flag |
| `produce` / `post_condition` stages | `Continuation.produce`, `post_condition` | (none) | Stage badges on the arm (`! each i {…} when …`) | `each`-loop pipeline stages |
| catchall `\|*` / `!*` + metatype | `is_catchall`, `catchall_metatype` | (none) | Residual arm block ("any other outcome") | `|* Transition t` binds the metatype record |
| binding annotations `[mutable]` etc. | `binding_annotations`, `binding_marks` (`@scope`) | (none) | Badge on binding socket | `[mutable]` → `var` vs `const` at emission |
| return binding `(): r`, destructure `(): {x, y}` | `Invocation.return_binding`/`return_destructure`/`return_destructure_named` | Reporter "call and store" | Output socket on the call block | `-> name` binds bare-return; `{...}` destructures it |
| `when` on `for`/`each` produce stage | `post_condition` | "repeat until"-ish | Guard badge | Same guard machinery as `when` |
| field `default` `b: i32 = 5` | `Field.default` | (none) | Default-value field on input/param cards | Currently unprinted by `--print` (round-trip gap, below) |
| type annotations `Type[ann]` | `Field.type_annotations` | (none) | Badge on type text | Outermost suffix lane, distinct from `<>` phantom |
| `Source`/`Expression`/`InvocationMeta` param types | `Field.is_source`/`is_expression`/`is_invocation_meta` | (none — comptime introspection) | Comptime params = property card / macro-ish badge | These make events comptime-only (`EventDecl.isComptimeOnly`) — arguably hideable from a runtime view |
| `~if`/`~for`/`supervised`/etc. transforms | (invisible — pre-transform AST) | C-blocks (`if`, `repeat`) | Rendered as their *user surface*: `if(c) \| then \| else`, `for(r) ! each` — ordinary invocation + arm blocks | The transform layer is below the editor's floor; keyword-ness is an annotation, not syntax |

## 7. State and effects — the Scratch-variable story

| Construct | AST | Scratch analogue | Treatment | Notes |
|---|---|---|---|---|
| `capture { f: v }` + `! as c` + `captured { f: expr }` + `\| captured r` | `control:capture` tor → lowers to `Node.assignment` + preamble | **Variable get/set/change** — the closest thing to a real mapping | **Variable block**: cell card (fields), `captured {}` as "set field" reporter/stack | Capture IS the variable: declared fields, typed record, commit boundary. `control:capture` = local cell; `std/cell:capture` = persistent cell over a store — same surface, two scopes |
| `std/store:query`/`stripe` watch `std/store(name) ! field` | stdlib tor invocations | "when I receive" hat on a named source | Hat block "when store.field changes" + body stack | The broadcast analog: named state-change subscription |
| broadcast-like event send | `Invocation` of an event | "broadcast [msg]" stack block | Call block (events ARE the messages — typed, declared) | Koru events are compile-time dispatch, not runtime strings |
| `event_tap` (see §5) | `EventTap` item | (none) | Aspect panel only | Wildcard source/dest interception — keep at arm's length per user ruling |

## 8. What Scratch has that Koru doesn't (drop list)

Sprites/stage actors, costumes/backdrops, cloning, pen, video/audio
sensing, "wait N seconds" as a primitive, dynamic untyped broadcast
strings, the fixed 125-block palette. None of these are gaps to fill —
they're category differences. The editor inherits whatever stdlib tors
exist (`std/io`, `std/rand`, `std/field`, …) as palette entries.

## 9. What Koru has that Scratch can't express (the ceiling list)

Phantom types and obligations, effect branches with resume sums,
open/declared branch vocabularies, destructuring, `when` guards on arms,
catchalls, binding/type annotations, comptime `Source`/`Expression`/
`InvocationMeta` capture, transforms, `part` modules, `.kz` host
embedding, multi-target variants. A Scratch-style editor covers the
imperative flow core completely and must decide per-construct above
whether the obligation layer gets shapes or stays cards/text.

## 10. Serialization legs — measured state (this session)

The pipeline a block editor needs already exists and is load-bearing:

- **AST → JSON**: `ast_json.zig` reflective dump, generic over all
  fields (`--ast-json`, `--ast-canon`). Used by the metacircular backend.
- **JSON → AST**: same module reconstructs the typed `Program` — the
  backend reads it at runtime.
- **AST → source**: `ast_printer.zig` + `--print`. Corpus round-trip
  via `scripts/roundtrip_harness.sh` (now enrolled as
  `./run_regression.sh --roundtrip [filter]` — delegates like
  `--todo-sweep`, writes no snapshot). **Latest run (2026-11-08, after
  two fixes): 1747 pass / 178 fail / 157 skip** of ~2082 positive
  tests. The fixes: (a) `had_explicit_label` reclassified as canon
  trivia alongside `location`/`indent` (`ast_json.isTrivia`) — it is
  pun-vs-explicit spelling provenance, not program; (b) harness
  facet bug — reparse file now mirrors the source extension (`.k` →
  `input.k`), since `--print` emits facet-matching dialect. Remaining
  178 fails: **87 tree-diff** — all real printer gaps, no provenance
  left (field histogram: `expression_value`/`scope`/`bindings` Source
  captures, `produce`/`post_condition` stages, `part` decls
  `parts`/`tag`, continuation-regrouping clusters, destructure subs,
  `module_path`, comment `content`); **81 unprintable** = documented
  ungrounded spellings (chain-after-branch 34, call-site-variant 20,
  transform annotations 13, continuation-without-node 8, source-block
  phantom 5, immediate_impl annotations 1); **10 reparse-error**.
  ~84% → **~89% clean pass**; the gap list is now purely semantic.
- **IDE groundwork**: `frontend_introspect.zig` (parse+imports, powers
  `glance`, names hover/definition as future work),
  `frontend_hover.zig`.
  Editor ecosystem already exists in sibling repos: `koru-vscode`,
  `monaco-koru-mode`, `tree-sitter-koru`, `zed-koru` (syntax/modes);
  korulang.org carries a navigable AST visualization.

### What parse throws away (the loss inventory)

Preserved in the tree: every item, shape, branch, binding, destructure,
produce/post_condition stage, annotation, `prose`, `Source`/`Expression`
captures (text+scope), `location`/`indent` trivia, and
`had_explicit_label` provenance. Expressions are mostly stored as
strings — opaque text that *cannot* fail to round-trip; real `ExprNode`
trees are optional enrichments (`condition_expr`, `parsed_expression`)
with the string always underneath.

Thrown away:

- **`.k` comments — the only semantic-content loss.** Dropped at
  `parser.zig:1425` (`isCommentLine → continue`). `.kz`/`.kjs`/`.kmd`
  comments survive as `host_line` items, unclassified.
- **All whitespace, blank lines, and formatting** — trivia by design;
  the normalized form does not preserve it and does not need to.
- **`.kz` `~` sigils and facet markers** — dialect encoding, not AST.
- **Pun-vs-explicit-label preference on print** — `had_explicit_label`
  survives in the AST but canonical print normalizes `f(x)` → `f(x: x)`-
  style explicit labels, producing the 1212 provenance-only tree-diffs.
  Arguably belongs in the canon trivia strip alongside `location`/`indent`.

Everything else the parser sees either lands in the tree or is a
documented unprintable spelling (§10). For pure `.k`, the loss surface
is: comments + formatting + one provenance flag. That is an unusually
small loss surface — the closed node set (7 parser-produced `Node`
kinds, ~11 source `Item` kinds) and the expressions-as-strings floor
are what make it so.

**The normalized-form idea is already built**: `--print` IS the
canonical/prettified form, and `scripts/roundtrip_harness.sh` is the
enforcer (`parse(print(parse))` tree-equal + `print(parse(print))`
byte-equal). The lenient-parser/strict-canonical split the design
calls for is the de facto architecture: the parser accepts many
spellings (the two-spellings-one-tree diffs prove it), `--print`
emits exactly one, and the backend consumes the AST/JSON and never
sees surface at all.

**"Fully round-trippable" = the enumerable gap list**: 87 real field
diffs (Source/Expression scope captures, produce/post_condition,
part decls, chain regrouping, destructure subs, module_path, comment
content) + 81 unprintable spellings + 10 reparse. Bounded worklist,
not a chasm — the same shape as every other gap-closing program in
this repo. ~~`had_explicit_label` canon-trivia question~~ — resolved
2026-11-08: stripped from canon (provenance, not program). The open
ruling that sizes it: teaching tool (canonical normalization
acceptable) vs real editor (untouched regions must survive
byte-identical → comments and the 87 diffs become blockers, not
polish).

## 11. Transform-effect census (measured this session)

Question commissioned: are tor declarations strong enough to drive an
editor, or does a capability sidecar ("trellis") need inventing? Census:
every transform implementation in `koru_std` (`.kz`/`.k`), classified by
the effect mechanisms its body actually uses (`SiteResult` fields +
flow-mutation channels).

**Scale**: 62 `~[transform]proc` bodies found by annotation scan, plus
bare `~proc` transform impls the scan misses (`tap` at `taps.kz:44`,
`ctx default` at `ctx.kz:657` — the tor carries `[transform]`, the proc
doesn't). Real count ≈ 64 procs over ~60 transform tors. 4 are `|js`
twins of `|zig` transforms (regex match/scan, json emit/parse). 64
`[keyword]` tor decls total — the user-facing convenience palette.

**Effect mechanisms actually used** (union across all procs):

| Mechanism | AST channel | Procs using it | Class |
|---|---|---|---|
| local rewrite | `SiteResult.replacement` / `replacement_node` | ~55 — nearly universal | A: local rewrite |
| synthesize top-level items | `SiteResult.appended` | ~20 (store.new/query, channel.new, grid.*, regex.*, rings.new, pump.*, parser.parse, json.parse, field.mark-multiples, supervised) | B: +appends items |
| inject host decls / emission | `preamble_code`, `inline_body` | ~15 (store.new/insert/take/clear/default/rule/stored/stripe, cell.open, channel/node/constructor `default`, field.new.on-stack, cli.default) | C: +injects code |
| graft continuation subtrees | `is_transformed_subtree` | 4 (cell.capture, panic.catch, parser.grammar, supervised) | D: +subtree grafts |
| reroute producer / site views | `retarget_producer`, `siteView`, `site_of` | 3 (supervised, store.query, store.new) | E: +producer retarget |
| rewrite whole program | `SiteResult.whole_program` | **2** — `tap` (taps.kz:1450), `ctx default` (ctx.kz:684); both bare `~proc`, not `[transform]proc` | F: whole-program |
| bookkeeping marks | `@pass_ran`, `@shape_valid`, `marks` | ~8 — orthogonal to effects | (not an effect class) |

**Arm relations** — the second axis the census exposed:

| Relation | Meaning | Examples |
|---|---|---|
| routed | arms are real dispatch; transform lowers emission, semantics preserved | `for`, `if`, store ops, `supervised` |
| consumed | arms are scaffolding the transform dissolves (`! as`/`| captured` → cell preamble + assignments) | `control.capture`, `cell.capture`, `panic.catch` |
| read-as-data | arms are a table the transform interprets (patterns, schemas) | `trellis define` (arms = path-regex law), `json.parse` (destructure groups = schema) |

**Verdict on the trellis question**: the tor declaration is strong
enough for the *routing contract* — signature → arg sockets (with
capture-kind flags), branches → arm blocks, `?`/`?!`/effect/resume → arm
badges — and the shape checker already enforces it. What's undeclared
is exactly two small axes: **effect class** (~6 mechanism classes, all
already named in `SiteResult` + flow channels) and **arm relation**
(3 values). That is an annotation enum, not a capability calculus — no
trellis needed at this census size. The classes exist in the ABI; the
signature just doesn't say which apply. `SiteResult` is the spec the
sidecar would mirror.

**What the editor actually needs**: nothing from this census for v1 —
the pre-transform AST is fully described by signatures alone. The
effect/arm-relation metadata only matters for *bespoke presentations*
(`capture` as variable block, `store.watch` as hat block, `trellis` as
law card) and any future "what does this construct do" surface. If
built, the cheapest honest form is a `[dissolves]`/`[appends]`-style
annotation vocabulary on transform tors — or riding the existing
`[explainer]` channel (`ExplainReport` already emits typed property
entries with witness hashes).

## 12. Keyword palette census (measured this session)

All 63 `[keyword]` tor decls in `koru_std`, by signature. The census
splits into three populations — and the split corrects an assumption:
`[keyword]` does NOT mean "syntax." Most keyword decls are
**macro-call surface**: `[keyword|comptime|transform]` tors whose
`expr: Expression` / `source: Source` params are *fragment sockets* —
raw program text the transform re-parses (the capture-kind flags
`is_expression`/`is_source` is exactly how the editor knows the socket
takes a fragment, not a value).

**Tier 1 — syntax keywords, bespoke or semi-bespoke shapes (~20 decls):**

| Tor | Signature | Shape |
|---|---|---|
| `if` | `expr: Expression` · `\| then` · `\| ?else` | C-block — the if |
| `for` | `expr`, `keep: ?Expression` · `! ?each` · `! ?reverse-each` · `! ?else` · `\| ?done` | C-block — the loop; effect arms feed items |
| `cond` | `expr: Expression` · `\| c *` | multi-arm dispatch block |
| `capture` (control) | `source: Source` · `! as` · `\| ?captured` | **variable/cell block** — the Scratch-variable analog |
| `const`, `slice` | `source: Source` (+expr) | declaration blocks (`[keyword\|declaration]`) |
| `from`, `sum`, `gaps` | `expr`, `source` (table.kz) | declaration helpers |
| `supervised` | `source: Source` | policy/fold block — complex, advanced tier |
| `tap` | `expr` | **aspect panel, not a block** (§5 ruling) |
| `test`, `test.with-harness`, `test.harness` | `expr` | test-declaration hat blocks |
| `assert`, `assert.ok/.fail/.eq/.contains` | expr variants | assertion stack blocks — generic-able |

**Tier 2 — comptime type constructors (~5 decls, not runtime blocks):**
`proto`, `string`, `int`, `float`, `bool` (types.kz) — `[keyword|
comptime|transform]` material constructors; type/property cards or
hidden from a runtime view.

**Tier 3 — macro-call family (~38 decls), generic call blocks:**
channel new/default/consume/send/recv/close; grid new/pool/stored/
sweep; node spawn/default/new; pump default/run; rings new/enqueue/
dequeue; store clear/default/insert/new/preorder/query/rule/stored/
stripe/take/view/watch; cell capture/open; ctx/cli/constructor
defaults; liquid `emit`; io `print`/`print.ln`/`eprint`/`eprint.ln`.
Ordinary invocation surface — the transform interprets the fragment
args. Generic stack-block treatment with **fragment sockets**; per-
library bespoke presentation optional (`store.watch`→hat,
`store.query`→chain step, `store.new`→declaration card).

**Palette consequence**: the editor's primitive tier is ~15-20 bespoke
shapes (if/for/cond/capture/const-family/supervised/tap-panel/test/
assert), NOT Scratch's 125-block fixed palette — Koru's generative arm
blocks carry the rest. Every Tier-3 decl renders correctly from its
signature alone; no capability metadata needed (§11).

## 13. Authoring-first direction (commissioned 2026-11-08)

Design pivot: prefer **compose → write** over **parse → render → edit**.
The editor's primary flow is blocks → AST → canonical `.k` source;
reading existing files is secondary.

**Why this collapses the hard requirement**: authoring-first never
parses arbitrary Koru — only Koru the editor itself emitted, which is
canonical by construction. The round-trip obligation shrinks from
"every spelling in the 2077-test corpus" (§10's gap list) to "every
construct the editor can produce" — the ~63-decl keyword palette +
generative arm blocks of §12. The corpus harness remains the
verification instrument (it proves the printer emits parseable
canonical source), but the pass-bar drops to the editor's own output
subset.

**`.dotk` as the save format**: the natural spelling is *canonical
`.k` source itself* — `printProgram` output is already valid pure-Koru
`.k` (no `~` sigils, `PrintOptions.tilde = ""`). A `.dotk` extension
would then be a *marker* ("this file is editor-canonical, safe to
rewrite wholesale"), not a new language — satisfying the
source-stays-editable constraint for free, since `.dotk` IS text Koru
`koruc` already reads. Alternative: `.dotk` = the AST JSON itself —
rejected by the same constraint (JSON is not human-editable source).

**Pipeline status — every leg exists**: blocks → JSON AST (editor
side) → `ast_json` deserialize → `ast.Program` → `printProgram` →
file. The only missing pieces are the block UI and whatever thin
`koruc` mode exposes deserialize+print as a CLI step.

**What IS still hard about reading back** — precisely:

1. *Files the editor wrote*: nothing. Canonical source parses to the
   tree it came from — the round-trip contract, already enforced.
2. *Foreign `.k` files*: parse is universal (the parser accepts every
   spelling — that's why two-spellings-one-tree diffs exist), but
   (a) render coverage = the §2-§7 shape table, with opaque cards for
   the unshaped remainder, and (b) **re-emission fidelity**: opening a
   messy hand-written file and saving rewrites the whole file to
   canonical form — comments (until the commissioned fix lands),
   formatting, pun preferences, and the §10 real diffs all normalize.
   The `.dotk` marker solves this honestly: editor-owned files get
   wholesale canonical rewrite; foreign `.k` opens read-mostly or
   behind an explicit "normalize on save" consent. Region-preserving
   edit (untouched bytes survive) is the real-editor bar and is NOT
   required for v1.
3. *The actual hard part was never round-tripping* — it's the block
   UI itself: drag/drop, socket typing, generative arm blocks from
   `EventDecl.branches`, and fragment-socket editing (a socket
   containing arbitrary Koru needs nested text editing inside a
   block). Round-trip was the measured-and-mostly-done part.

**Spike results (2026-11-08, dice.k)**: Leg A proven — `--print`
output re-prints byte-identical (fixed point) and the printed source
compiles and runs (`koruc run` reached the interactive prompt).
Leg B proven — `test "ast-json deserialize -> canonical print
composition"` in `ast_printer.zig` (2026-11-08): parse →
`ast_json.serialize` → `ast_json.deserialize` → `printProgram`
produces byte-identical canonical source to the direct
parse→print path, under `zig build test-ast-printer`. The full
authoring pipeline — editor-built JSON AST → `Program` → `.k`
source — is now verified end-to-end at every leg.

## 14. Open design questions

1. **Effect blocks**: the only construct with zero Scratch coverage —
   shape language for payload-out + resume-in + multi-arm resume.
2. **Generative palette**: arms minted from `EventDecl.branches` means
   the editor needs the whole program's decls to render one flow —
   `frontend_introspect` already resolves imports for exactly this.
3. **Expression promotion**: render `parsed_expression`/`condition_expr`
   where present and promote the rest lazily, or keep text sockets
   everywhere (Scratch hybrid)?
4. **Facet scope**: `.k` only (pure Koru, migration direction per
   `kz_convertible.sh`) with `.kz` host regions as opaque cards?
5. **Comments**: `.k` comment capture into the AST — commissioned
   separately; the editor inherits whatever lands.
6. **Where transforms sit**: editor works pre-transform — but `capture`'s
   "variable block" treatment keys on a *name* (`capture`/`captured`),
   not a node kind. Census answer (§11): the honest key is a declared
   **arm relation** (`routed`/`consumed`/`read-as-data`) plus **effect
   class** — an annotation enum, not a keyword registry. Until it
   exists, name-keying the ~64 `[keyword]` decls is acceptable
   presentation.
