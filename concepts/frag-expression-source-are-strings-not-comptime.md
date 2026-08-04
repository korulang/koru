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
