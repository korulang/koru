# Compiler Annotations

**Status:** Catalog and architectural notes captured 2026-05-29. Documents
the third category of bracket-syntax usage in koru, alongside phantom types
(`<>`) and obligations (a subset of phantoms).

## The three things bracket syntax means in koru today

After the phantom-syntax cutover (2026-05-29), koru distinguishes three
distinct categories that previously all shared `[]`:

1. **Phantom types** — `<>` (value-level, runtime-flowing, semantic-check-
   triggering). See `UNITS_OF_MEASURE.md` and `TAINT_TRACKING.md`.
2. **Obligation phantoms** — `<...!>` (subset of phantom types, with the
   discharge requirement). Same `<>` syntax, `!` marker distinguishes from
   labels-without-obligation.
3. **Compiler annotations** — `[]` (declaration-level metadata for the
   compiler and transforms). NOT runtime-flowing. NOT phantom-checker-
   relevant. This document.

## The distinguishing test

When you see brackets attached to something in koru source, ask: **does the
content flow with values at runtime / trigger semantic checks?**

- **Yes** → phantom (use `<>`)
- **No, it's purely metadata for the compiler/transforms** → annotation (use `[]`)

`*File<opened!>` — the `<opened!>` is a per-value state; close() discharges
it; the type system enforces. Phantom.

`Source[text]` — the `[text]` is a hint about what kind of source content
is expected. No per-value state. No discharge. Just informational for
transforms. Annotation.

## Current annotation uses

### Default-discharge annotation: `~[!]event close { ... }`

The leading `[!]` annotation block (before `event`) marks an event as the
**default discharge** when multiple events could discharge the same obligation.
Parsed into the event declaration's `annotations` array (`AnnotationBlockResult`
in `src/parser.zig`); consumed by `eventHasDefaultAnnotation` in
`src/auto_discharge_inserter.zig`. Pinned by
`tests/regression/300_ADVANCED_FEATURES/330_PHANTOM_TYPES/330_049_default_discharge_annotation`.

```koru
~[!]event close { conn: *Connection<!active> }
| ok
```

If `~event close` and `~event close_and_delete` both accept
`*Connection<!active>`, the `[!]` on close marks it as the default the
discharger picks first.

### Generic event-name parameters: `~event ring.new[T:u32;N:1024]`

Generics on event names use `[...]` with semicolon-separated typed
parameters. Documented in
`tests/regression/700_EVENT_GLOBBING/700_010_generics_bracket_syntax/`.
The parser captures the brackets as part of the event-name string; the
transform parses them at AST-walk time.

```koru
~ring.new[T:u32;N:1024](name: "my_ring")
```

### Event modifier annotations: `~[comptime|transform]event ...`

Annotation block BEFORE the construct. Uses `[a|b|c]` separator with `|`.
Includes `[comptime]`, `[transform(name)]`, `[norun]`, `[abstract]`, `[pub]`,
`[priv]`, `[inline]`, `[cold]`, `[hot]`, `[deprecated]`, etc.

```koru
~[comptime|norun]pub event requires.system { source: Source }
```

Same annotation-block parser as event-name trailing annotations
(`src/parser.zig:802` — `parseAnnotationBlock`).

### Source-block type hints: `Source[text]` *(currently broken)*

Annotation on a type in a field declaration to hint what shape of source
content the field will hold. Used in exactly one place
(`tests/regression/200_COMPILER_FEATURES/210_PARSER/210_039_file_source_syntax/`)
and currently failing — see that test's `TODO` file.

```koru
~[comptime|transform]event render.file {
    source: Source[text],
    program: *const Program,
    allocator: std.mem.Allocator
}
```

The `[text]` was meant as a hint to transforms about what kind of content
the source contains. Different from the event-modifier annotation block
shape (this annotation rides on the type, not the event name).

Status: aspirational. Parser doesn't yet implement annotation-extraction
on type positions post-cutover. Either needs proper implementation (new
`annotation` AST field separate from `phantom`) or the feature gets dropped.

### Call-site source-block annotation: `~event [Type]"path"` and `~event [Type]{ ... }`

`~render.file [text]"hello.txt"` reads `hello.txt` as a Source at compile
time and binds it to the event's source field. Same shape with braces
loads inline content: `~renderHTML [HTML]{ ... }`. Parser at
`src/parser.zig:2842-2861`.

Currently broken (same cutover side-effect as `Source[text]`). Used only
in documentation examples and the one failing test. Open question whether
to revive or remove.

## Why `[]` was kept for annotations after the phantom cutover

Phantom types are *value-level* — they belong to runtime values, get checked
by semantic passes, flow through expressions. The `<>` syntax was chosen
because:

- `<>` doesn't conflict with Zig's type-modifier syntax
- `<...>` after a value/expression has unambiguous parsing (`>` without RHS
  doesn't fit Zig grammar) — enables literal-suffix annotation like
  `22.5<celsius>`
- Visual unmistakeable as koru-territory

Annotations are *declaration-level* — they belong to declarations, not
runtime values. Different category, different role. `[]` was already the
established annotation syntax (`[!]`, `[comptime]`, generics), and keeping
it preserves recognizability for koru authors familiar with the existing
annotation patterns.

The split also reflects an architectural fact: phantom-checker passes live
in the `analysis` stage of the pipeline; annotation-consuming code lives
in the `frontend` and `transform` stages. Different lifecycle, different
consumers.

## Open architectural questions

1. **Should annotations on type positions exist at all?** Today `Source[text]`
   is the only experiment. Bare `Source` is the stdlib norm (10+ uses).
   Decision pending — see the `210_039` test's `TODO` file.

2. **Should the annotation-extraction code be unified?** Today there are at
   least three annotation-block parsers (`parseAnnotationBlock` at
   `parser.zig:802`, trailing annotations at `parser.zig:1262`, source-block
   `[Type]"path"` at `parser.zig:2842`). Each grew independently. Probably
   worth unifying when the next annotation feature lands.

3. **Should there be a registered set of valid annotations?** Today the
   parser accepts any string in `[...]` and downstream consumers either
   recognize them or silently ignore. A registered set would catch typos
   (`[comptme]` vs `[comptime]`) but reduce extensibility.

4. **Where do user-defined annotations fit?** The annotation system is
   extensible in principle (downstream transforms can recognize arbitrary
   annotations) but in practice everything is hardcoded. A future direction:
   let user code declare what annotations it accepts and have the parser
   validate.

## Related

- `UNITS_OF_MEASURE.md` — dimensional algebra on phantom types
- `TAINT_TRACKING.md` — obligation propagation through arithmetic
- `tests/regression/200_COMPILER_FEATURES/210_PARSER/210_039_file_source_syntax/TODO`
  — the test pinning the open decision on type-position annotations
- `koru_std/compiler.kz:614` — the pluggable compilation pipeline annotations
  hook into
