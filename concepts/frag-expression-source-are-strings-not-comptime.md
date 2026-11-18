---
type: belief
id: frag-expression-source-are-strings-not-comptime
provenance: introduced by d7d027b5 — feat(lang): decouple Expression/Source from comptime — representation != timing
ts: 2026-07-07
---

# Expression/Source are captured strings — NOT a comptime signal (belief)

A declared `Expression` or `Source` param is a *representation* choice: the
argument is captured as an opaque source string (Expression = the arg text +
scope; Source = a raw code block) instead of an ordinary value. That is
**orthogonal to timing** — to *when* the tor runs. Representation and
timing are two axes, and the language must not infer one from the other.

Ruled by Lars 2026-07-07, reversing the prior coupling: "the idea of
expression is basically just a way to pass a string — it's literally just
another way of passing a string, and that could survive at runtime the same
way it survives at comptime." Comptime-ness is now **explicit**: a tor is
comptime-only iff it carries `[comptime]` (or `[norun]`), or takes a
`Program`-typed param (the genuine metacircular compiler AST).

**Why the coupling was wrong.** The old rule auto-stamped `[comptime]` on any
tor with an `is_expression`/`is_source` field (parser), and the emitter
independently inferred comptime from the same fields (`has_comptime_params`,
`flowInvokesComptimeEvent`). That conflated "this arg is a captured string"
with "this whole event is pure-comptime and emits no runtime code." It is
false for the entire `[keyword]` template surface — `~if`/`~for` **consume**
an expression at compile time to **generate** a runtime Zig loop/branch
(comptime-eval, runtime-emit). The auto-flip filtered their lowered code out
of the runtime module, dropping the flow's own branch tors (e.g. a `~for`
loop's `process`/`finalize`). The `[]const u8`-typed hack on `if`/`for` had
been dodging the flip by keeping the arg off the expression rail — a
route-around that hid the defect for months.

**The fix (2026-07-07), three coupling heads severed, one kept:**
- parser: deleted the auto-`[comptime]` stamp (`parser.zig`, was ~1845).
- emitter: `has_comptime_params` and `flowInvokesComptimeEvent` (AST branch)
  now key off the `[comptime]`/`[norun]` annotation, not `is_expression`/
  `is_source`. `Program`-typed params still count (metacircular).
- KEPT conservative: `flowInvokesComptimeEvent`'s TypeRegistry fallback still
  uses the field-check — TypeRegistry stores no annotations, so an *imported*
  comptime tor not present in the local AST can't be re-classified there
  yet. An open edge.

**Blast radius = correctness.** 8 stdlib tors leaned solely on the flip,
ALL `[keyword]`/`[keyword|declaration]` (`if`/`for`/`from`/`sum`/`gaps`/
`const`/`assert.eq`/`assert.contains`) — exactly the runtime-emitting/
declaration surface that must never be pure-comptime. All 21 genuinely-
comptime tors already declared it explicitly. Migration cost: tors that
DO splice at compile time now say `[comptime]` (e.g. tests 020_010, 210_037).
`~if`/`~for` lower correctly through the (already expression-aware) template
system: `template_processor.renderTemplateInvocation` reads
`expression_value.text` as the string, no `[expand]` path involved.

Pairs with [[frag-arguments-are-atoms]] (the quoting-surface exemption keyed
off the declared param type) and the PARSE006 punning wall (a bare arg must
pun to a parameter, or bind implicitly to an `expr: Expression` / `source:
Source` slot). Same session, same principle: the declared *type* is the
contract, and it means exactly one thing — never a smuggled second one.

**2026-10-02 — the ruling is now true end-to-end.** Three stale walls still
treated the flags as timing after the decoupling: `emitArgs` refused a
runtime-position Source/Expression arg outright (`ComptimeEventNotTransformed`),
`evaluate-comptime` classified every `is_source` tor as comptime and stripped
its procs from the runtime AST (the "nothing implements" stub), and the
type-home collector let a captured field's bare name backfill whichever module
merely *aliased* it — `const Source = ast.Source` in std.compiler welded the
comptime module into runtime output. All three now key on `Program` or the
capture flags, never on the name. Verified: a runtime `|zig` proc receives
`"2 + 3"` for `expr: Expression` and raw block text for `source: Source`
(400_202, 400_203); quoted-form Source keeps the literal's spelling (quotes
included). A bare uncaptured name still resolves its home — `Invocation` →
`koru_interpreter` — because the flag, not the name, is the discriminator.
`EventDecl.isComptimeOnly()` still returns true for these fields on purpose:
its callers ask "is this input compiler-supplied", and captured text is.

**2026-10-03 — "end-to-end" missed one classifier.** The 10-02 rewrite
dropped `is_source` from `evaluate-comptime`'s strip map but kept no
annotation leg, so a `[comptime]` decl taking `Source` — `std/build:config`
itself — fell out of the map; its armless invocation flow stayed in the
runtime AST and failed branch coverage (KORU022), breaking every
`~std/build:config {}` call site including the vercel reactor entry.
`record()` now counts `Program` params OR the `[comptime]`/`[norun]`
annotation — the same contract `flowInvokesComptimeEvent` has always
routed by. 310_057, the pin for the exact shape, had not been run since
the classifier landed.

**2026-11-17 — R1 lands the value-position wall (KORU118).** The ruling
"call-site text only" finally gets a declaration-time refusal: capture kinds
(`Expression`, `Source`, `File`, `EmbedFile`, `InvocationMeta`) in a return
type, resume type, resume arm, or outcome payload refuse in
`host_type_scope_checker` — where `-> Expression` used to emit
`pub const Output = Expression;` (undeclared Zig, backend crash) and
`| exact Expression` crashed the same way. Bare `Program` refuses too, except
where the event is a comptime transform (`isComptimeOnly()` or a
`[comptime]`/`[transform]` annotation) — `-> *const Program` is ABI there
(210_054, 220_023).

The load-bearing nuance the wall surfaced: **capture-kind-ness is a property
of the position, not the spelling.** On the INPUT shape, `program_ast:
*const Program` (compiler.kz `context-create`) and `source: *const Source`
(testing.kz `validate-mocks`) are legitimate *runtime handles* — the
metacircular pipeline passes the seed AST around as data. Neither spelling is
flagged by the parser (`isComptimeOnly` keys only the exact `Program` name)
and neither may refuse. The capture gate is the bare unqualified param
spelling; the pointered forms are data.
