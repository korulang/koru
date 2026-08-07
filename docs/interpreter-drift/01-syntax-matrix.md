# Interpreter Syntax Matrix — how far `flow_parser` has fallen behind the compiler parser

**File:** `docs/interpreter-drift/01-syntax-matrix.md`
**Agent:** SyntaxMatrix · **Date:** 2026-08-07

## Method

Every interpreter verdict below is **OBSERVED**, not predicted. I compiled and ran four
probe programs with the existing `zig-out/bin/koruc` (no rebuild) and captured the real
`std/runtime:run` output. Sources live under `/tmp/syntaxmatrix/` (`probe.kz` 35 rows,
`verify.kz` 10 value-semantics rows, `shell.kz` 4 shell-case rows). The probe harness is
the shape of `tests/regression/400_RUNTIME_FEATURES/430_RUNTIME/430_043_runtime_run_scope/input.kz`:
events are declared and registered into scope `"s"`, then each construct is fed to
`~std/runtime:run(source: S, scope: "s")` and the branch + message is printed.

Compiler-parser verdicts are grounded in reading `src/parser.zig` and the fact that each
form is standard Koru used by `koru_std/` and the regression suite; the interpreter's own
fallback to the full parser (`koru_std/interpreter.kz:1166`) is what produces the
`PARSE-ERROR: No flow found in source` message when the full parser also fails.
These are marked **[inf]** (source/tests) vs the interpreter verdicts which are all observed.

## Legend (interpreter verdicts)

- `RESULT branch=X` — parsed and executed; final branch `X`.
- `PARSE-ERROR msg=No flow found in source` — `flow_parser` failed AND the full-parser
  fallback found no flow. This is the combined "neither parser accepts it" signal.
- `DISPATCH-ERROR event=.. msg=NoBranchMatch` — parsed, but no continuation arm matched
  the branch the event produced.
- `EVENT-DENIED` — parsed, but the (dotted/qualified) event name is not in the scope's
  dispatcher. Parse succeeded; lookup failed.
- Bare-return events (`-> type`) are pinned by the passing regression test `430_043` (SUCCESS).

## The matrix

| # | Construct | Example (fed to `run`) | Compiler | Interpreter verdict (observed) | flow_parser locus |
|---|-----------|------------------------|----------|--------------------------------|-------------------|
| 1 | bare invocation | `basic()` | Y | RESULT branch=done | `parseInvocationLine:239` |
| 2 | labelled arg | `hello(name: "World")` | Y | RESULT branch=done | `parseInvocationLine:239; lexer.parseArgs` |
| 3 | positional arg | `hello("World")` | Y | RESULT branch=done — but value is EMPTY (positional never binds to the named param; see value table) | `lexer.parseArgs shorthand:399+` |
| 4 | punned arg | `hello(World)` | Y | RESULT branch=done — but value is EMPTY (punned name does not bind to `name`; see value table) | `lexer.parseArgs shorthand:399+` |
| 5 | dotted event name | `a.b.c` | Y | EVENT-DENIED — three-segment path parsed OK, name not in scope | `parseQualifiedPath (lexer); parseInvocationLine:239` |
| 6 | module-qualified call | `s:hello(name: "x")` | Y | EVENT-DENIED — qualifier `s` parsed, event `s.hello` not registered | `lexer.parseQualifiedPath` |
| 7 | module-qualified slash | `std/io:pri` | Y | EVENT-DENIED — qualifier `std/io` normalized to `std.io`, name not in scope | `lexer.parseQualifiedPath `/`->`.`` |
| 8 | `|` branch arm (own line) | `basic()\n| done v` | Y | RESULT branch=done | `parseSingleContinuation:481` |
| 9 | `|>` chain step after a `|` arm | `add(a: "1", b: "2")\n| sum v |> hello(name: v)` | Y | RESULT branch=done — value `v` threaded; chain runs | `findPipeGt:561; parseNode:717` |
| 10 | top-level `|>` (no branch arm) | `basic()\n|> hello(name: "x")` | Y | DISPATCH-ERROR NoBranchMatch — a bare `|>` on the head has branch="" and matches basic's `done` branch against nothing | `parseSingleContinuation:493 pipeline branch=""` |
| 11 | multi-branch arms | `div(a: "4", b: "2")\n| ok v |> hello(name: v)\n| err e |> hello(name: "FAIL")` | Y | RESULT branch=done — both arms parsed, `ok` fired | `parseContinuations:359` |
| 12 | `!` effect arm | `basic()\n! done v |> hello(name: "eff")` | Y | PARSE-ERROR msg=No flow found in source | `parseSingleContinuation:485 — only `|`/`|>`/`|?` handled; `!` returns MalformedContinuation` |
| 13 | `!?` effect catch-all | `basic()\n!? v |> hello(name: "eff")` | Y | PARSE-ERROR msg=No flow found in source | `same as #12` |
| 14 | `|?` branch catch-all | `basic()\n|? v |> hello(name: "c")` | Y | DISPATCH-ERROR NoBranchMatch — `|? v` parses (is_catchall set) but `v` is stored as the branch name and never matches, | `parseSingleContinuation:489; parseBranchInfo:626` |
| 15 | `=>` branch constructor (fields) | `basic()\n| done v |> result { status: "ok" }` | Y | RESULT branch=result | `parseBranchConstructor:793` |
| 16 | `=>` branch constructor (plain value) | `basic()\n| done v |> result { 5 }` | Y | RESULT branch=result | `parseBranchConstructor:793` |
| 17 | braceless branch constructor | `basic()\n| done v |> ok` | Y | RESULT branch=ok | `isPlainBranchName:779` |
| 18 | `->` bare return (event decl) | `event declared `-> string` (see 430_043)` | Y | WORKS — pinned by regression `430_043` (PASS) | `(event-level; interpreter consumes bare-return branch)` |
| 19 | `:` binding mid-chain | `add(a: "1", b: "2")\n| sum v |> hello(name: v)` | Y | RESULT branch=done; bound `v` carries the payload (see value table) | `parseBranchInfo:626 binding` |
| 20 | nested/indented continuation | `basic()\n| done v |> add(a: v, b: "x")\n    | sum s |> hello(name: s)` | Y | RESULT branch=done — nesting parsed | `parseContinuations nested loop:411+` |
| 21 | multi-line args | `hello(\n  name: "World"\n)` | Y | RESULT branch=done | `collectMultiLineConstruct:178` |
| 22 | string escapes | `hello(name: "a\\nb\\\"c")` | Y | RESULT branch=done — BUT the value keeps `\n`/`\"` as literal chars (not unescaped; see value table) | `lexer.parseArgs skips escaped chars for splitting only; value keeps bytes` |
| 23 | `{{ }}` interpolation | `hello(name: "X")\n| done v |> echo(msg: "got {{ v }}")` | Y | RESULT branch=done — BUT `{{ v }}` is passed through literally, never rendered (see value table) | `arg value is raw text; no template pass in interpreter` |
| 24 | struct/record literal in arg | `hello(name: { a: 1, b: 2 })` | Y | RESULT branch=done — `{ a: 1, b: 2 }` passed as a literal string (see value table) | `lexer.parseArgs brace tracking; value kept raw` |
| 25 | expression in arg position | `add(a: 1 + 2, b: 3)` | Y | RESULT branch=sum — `1 + 2` NOT evaluated; passed as literal text (see value table) | `tryParseArgExpr:337 sets parsed_expression but dispatch feeds raw value` |
| 26 | terminal `_` | `basic()\n| done |> _` | Y | RESULT branch=discard | `parseNode:720 terminal` |
| 27 | quoted branch name | `basic()\n| `done` v |> hello(name: v)` | Y | RESULT branch=done | `parseBranchInfo:629 quoted decode` |
| 28 | `when` condition | `div(a: "4", b: "2")\n| ok v when v == "4" |> hello(name: v)\n| ok v2 |> hello(name: "other")` | Y | RESULT branch=done — `when` parsed and evaluated | `findWhenKeyword:699; condition on cont` |
| 29 | comment lines | `// a comment\n// another\nbasic()\n| done v` | Y | RESULT branch=done — leading/interspersed `//` lines skipped | `parseFlowInternal:77; parseContinuations:371` |
| 30 | multiple statements in one source | `basic()\nhello(name: "x")` | Y | RESULT branch=done — ONLY the first statement runs; the second is silently ignored | `parseFlowInternal parses one invocation; parseContinuations:406 breaks on non-continuation` |
| 31 | label `@loop` / back-edge | `for(0..3)\n@loop\n| each i |> echo(msg: i)\n| done |> hello(name: "end")` | Y | RESULT branch=done — the `@loop` line terminates continuation collection, so the loop runs with ZERO arms; label and back-edge are dropped | `parseContinuations:406 (`@` is not a continuation -> break)` |
## Value semantics — what actually arrives at the event (observed)

`std/interpreter:value.stringify` of the final result. These are the practical gaps for a shell / wire protocol.

| # | Construct | Source | Value received (observed) | Meaning |
|---|-----------|--------|---------------------------|---------|
| V1 | positional arg | `hello("World")` | `{"branch":"done","value":""}` | positional value is NOT bound to the named param; param is empty |
| V2 | punned bare name | `hello(World)` | `{"branch":"done","value":""}` | punned name is NOT bound to `name`; param is empty |
| V3 | bound value chaining | `add(a: "1", b: "2")\n| sum v |> hello(name: v)` | `{"branch":"done","value":"1"}` | chaining WORKS — `v` carries the scalar payload |
| V4 | field access on binding | `add(a: "1", b: "2")\n| sum v |> hello(name: v.num)` | `{"branch":"done","value":"<v.num>"}` | `v.num` is NOT dereferenced — passed as literal text |
| V5 | `{{ }}` interpolation (bound) | `hello(name: "X")\n| done v |> echo(msg: "got {{ v }}")` | `{"branch":"done","value":"got {{ v }}"}` | `{{ v }}` is NOT rendered — literal text |
| V6 | `{{ }}` interpolation (literal) | `echo(msg: "hi {{ nope }}")` | `{"branch":"done","value":"hi {{ nope }}"}` | same — no interpolation |
| V7 | expression in arg | `add(a: 1 + 2, b: 3)` | `{"branch":"sum","value":"1 + 2"}` | `1 + 2` NOT evaluated — passed as literal |
| V8 | struct literal in arg | `hello(name: { a: 1, b: 2 })` | `{"branch":"done","value":"{ a: 1, b: 2 }"}` | constructor literal passed as raw text, not built |
| V9 | string escapes | `hello(name: "a\nb\"c")` | `{"branch":"done","value":"a\\nb\\\"c"}` | `\n`/`\"` kept as literal backslash sequences; NOT unescaped |
| V10 | `{{ }}` in a head arg | `hello(name: "pre {{ x }} post")` | `{"branch":"done","value":"pre {{ x }} post"}` | literal |

## The shell case (the crux the ruling is for)

Exact line from `.../430_056_partially_handled_interpreted_flow/NEEDS_RULING`
`std/io:file.read(file: \"chat.txt\") | ok lines |> std/io:print.ln(\"Got files\")` — one line:

| Shape | Interpreter verdict (observed) |
|-------|--------------------------------|
| one line, head + `| ok` + `|>` | `PARSE-ERROR msg=No flow found in source` — **fails, exactly as the ruling says** |
| same, split over two lines | `EVENT-DENIED` — parses fine once the arm is on its own line |
| head + one `| ok lines` arm only | `EVENT-DENIED` (parses; event not in scope) |
| head with zero arms | `EVENT-DENIED` (parses; event not in scope) |

**Root cause of the one-line failure.** `flow_parser` splits the source into lines and parses
the invocation with `parseInvocationLine` (`flow_parser.zig:239`), locating args with
`findTopLevelParen` (`flow_parser.zig:279`), which returns only the FIRST `(`. The trailing
`|> std/io:print.ln(\"Got files\")` then leaves a second invocation's parens; `lexer.parseArgs`
strips one leading `(` and one trailing `)` and hits an unbalanced `)` -> `error.UnbalancedArgs`,
the whole invocation is rejected, `run` falls back to the full parser, and the full parser
finds no `.flow` item for bare invocation text -> `No flow found in source`. The interpreter
has **no notion of a continuation on the head line**; continuations must begin on their own line
(`parseContinuations`, `flow_parser.zig:359`).

A head with only `| done v` (no second `|>`) does NOT hard-fail: the `| done v` text is silently
swallowed as a junk argument and the event runs with no continuation. So the parse failure and
the semantic gap are separable, as the ruling notes.

## Constructs the interpreter cannot parse — ranked by likely shell/LLM use

1. **Head + arm on ONE line** (`e | ok x |> next(...)`) — the #1 shell shape. Hard `PARSE-ERROR`.
   A line typed at a prompt dies. (`flow_parser.zig:239,279`; severest because it is the default shell form.)
2. **`!` effect arms** (`e()\n! done x |> ...`, `!?`) — hard `PARSE-ERROR`. LLMs emit effects often.
3. **`@label` / back-edge loops** — the `@loop` line stops continuation collection; loop runs with zero arms. Dropped silently.
4. **Multiple statements in one source string** — only the first runs; the rest ignored silently.
5. **`|?` catch-all** — parses but dispatches `NoBranchMatch`; the catch-all never fires.
6. **Top-level `|>`** (a bare pipeline as the only continuation) — `NoBranchMatch`, not a parse error, but does not compose.

## Constructs the interpreter parses but whose SEMANTICS are hollow (value table)

These will silently corrupt a wire protocol / shell because the text is accepted and the event runs
but the payload is wrong: positional & punned args never bind to the param (`""`); `{{ }}` is never
interpolated; `1 + 2` is never evaluated; `v.num` is never dereferenced; struct literals `{ a: 1 }`
are passed as raw text; string escapes `\n`/`\"` are never unescaped.

## Appendix — raw probe output (selected)

probe.kz (35 rows) key lines:
  ROW[A_bare] RESULT branch=done
  ROW[A_positional] RESULT branch=done
  ROW[A_2dot] EVENT-DENIED
  ROW[A_qualified] EVENT-DENIED
  ROW[B_chain] RESULT branch=done
  ROW[B_catchall_pipe] DISPATCH-ERROR event=basic msg=NoBranchMatch
  ROW[B_nested] RESULT branch=done
  ROW[B_terminal] RESULT branch=discard
  ROW[B_bc_fields] RESULT branch=result
  ROW[B_effect] PARSE-ERROR msg=No flow found in source
  ROW[B_effect_ca] PARSE-ERROR msg=No flow found in source
  ROW[B_label] RESULT branch=done
  ROW[B_multistat] RESULT branch=done
  ROW[C_headpipe_chain] PARSE-ERROR msg=No flow found in source
  ROW[C_purepipe_1l] PARSE-ERROR msg=No flow found in source
  ROW[C_effect_1l] RESULT branch=done (swallowed)
  ROW[C_bc_1l] RESULT branch=done (swallowed)
shell.kz:
  ROW[Z_shell_exact] PARSE-ERROR msg=No flow found in source
  ROW[Z_shell_split] EVENT-DENIED
verify.kz (value.stringify):
  V_chain VALUE {"branch":"done","value":"1"}
  V_chain_field VALUE {"branch":"done","value":"<v.num>"}
  V_interp_bound VALUE {"branch":"done","value":"got {{ v }}"}
  V_expr VALUE {"branch":"sum","value":"1 + 2"}
  V_escapes VALUE {"branch":"done","value":"a\\nb\\\"c"}

