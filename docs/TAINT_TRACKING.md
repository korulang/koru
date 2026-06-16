# Taint Tracking (Obligation Propagation Through Arithmetic)

**Status:** Design captured 2026-05-29. Not yet implemented. This document
captures the architectural decisions made during the design conversation
about generalizing the obligation system to propagate through arithmetic on
phantom-tagged values.

**Note on stdlib signatures:** All `std/io:*`, `std/sanitize:*`, etc. examples
in this document use placeholder shapes for the parameters and types. The
exact stdlib API (parameter names, format-string handling, etc.) will be
worked out at implementation time. The *type-level taint behavior* is the
point of the examples, not the precise stdlib signature.

## The problem

Type-level taint tracking — "this value came from an untrusted source, must
pass through a sanitizer before reaching a sink" — has been a research darling
for 20+ years (JIF, FlowCAML, Jeeves, LiquidHaskell extensions). None of it
has shipped in a mainstream language. The closest mainstream attempts are:

- Perl's `taint` mode — *runtime* check, not type-level
- TypeScript "branded types" idiom — manual, fragile, no stdlib support
- C# `[Sanitized]` attributes — convention only, no checker
- Java's `@Tainted` (FindBugs/SpotBugs) — static analysis bolt-on, not type-system

Koru is uniquely positioned to provide compile-time taint propagation as a
**direct consequence of the existing obligation system**, with one design
extension: obligations propagate through arithmetic on phantom-tagged values.

The marketing line: **"the only language where SQL injection is a compile
error."** True and demonstrable, on the same architectural footing as
F# units of measure.

## The architectural insight

Today, the obligation system works on **complex types and references**:
`*File<opened!>` must be discharged by `close()` before the file is "free
to terminate." The discharge event consumes the obligation (`<!opened>` in
the parameter) and returns a non-`!` form.

The system works because labels are opaque strings and the obligation
checker scans for `!` markers. **There is nothing in the architecture that
restricts this to complex types.** Generalizing it requires one design call:
**`!` propagates through arithmetic as part of the opaque label string.**

```
a: f64<untrusted!>      b: f64<verified>

a + b   →   f64<(untrusted|verified)!>   // result is still tainted
a * 2.0 →   f64<untrusted!>              // scalar mul preserves taint
sanitize(a + b)  →  f64<verified>        // discharge clears !
```

The obligation checker doesn't need to understand units, arithmetic, or
composition. It just walks the label looking for `!`. If found, the value
is locked behind a discharge requirement. If `!` is absent, the value flows
freely.

This is symmetric with `UNITS_OF_MEASURE.md`: same pluggable-pass
architecture, same opaque-label substrate, different label semantics.

## Scope and label model

Taint is **context-specific**. There is no single "sanitized" state, because
HTML-safe is not SQL-safe is not shell-safe. The label space:

- `<untrusted!>` — from any external source; must discharge before any
  context-bound sink accepts it
- `<safe_html>` — escaped for HTML output
- `<safe_sql>` — escaped/parameterized for SQL
- `<safe_shell>` — escaped for shell argument position
- `<safe_url>` — URL-encoded
- `<safe_json>` — escaped for JSON output
- `<verified>` — generic "parsed and validated" (for non-text inputs)
- `<safe_console>` — passthrough acknowledgment for "print to terminal"
  (terminal escape sequences are technically an injection vector, this is
  the "I know, but it's fine" discharge)

Authors can add domain-specific safe-labels (`<safe_log>`, `<safe_email>`,
etc.) — the system is open.

**Sources** mark the entry point of untrusted data:

```
std/io:read.ln       →  []const u8<untrusted!>
std/io:read.env(k)   →  ?[]const u8<untrusted!>
std/io:read.file(p)  →  []const u8<untrusted!>
std/net:fetch.body   →  []const u8<untrusted!>
```

**Sinks** require specific safe-labels:

```
std/http:respond(body: []const u8<safe_html>)
std/sql:execute(query: []const u8<safe_sql>)
std/shell:exec(cmd: []const u8<safe_shell>)
std/fs:write(path: []const u8<safe_path>, content: []const u8)
```

**Discharges** are events that transition `<untrusted!>` (or arithmetic
derivatives) into a specific safe-label:

```
~event html_escape { s: []const u8<U!> }
| sanitized []const u8<safe_html>

~event sql_param { s: []const u8<U!> }
| sanitized []const u8<safe_sql>

~event shell_arg { s: []const u8<U!> }
| sanitized []const u8<safe_shell>

~event integer_parse { s: []const u8<U!> }
| parsed i32<verified>
| invalid []const u8
```

The discharge events use **state-variable phantoms** (the existing
`M'_` wildcard syntax from test 330_009 / 330_010) to be polymorphic over
the propagated unit / origin label.

**Permissive sinks** accept unions:

```
std/io:print.ln(...)  // accepts <untrusted|sanitized>, doesn't care
                      // (the exact signature is TBD; the type-level
                      // behavior is the point)
```

This is the existing union-phantom feature from test
`330_009_universal_wildcard_metatype` etc. — already supported by the
phantom system.

## Propagation rules

Same architecture as `UNITS_OF_MEASURE.md`. The obligation checker walks
labels looking for `!`. The composition rule: any arithmetic/transformation
on a `!`-bearing operand produces a `!`-bearing result.

```
a<untrusted!> + b<verified>   →   <(untrusted|verified)!>
a<untrusted!> + b<untrusted!> →   <untrusted!>     (single ! preserved)
a<untrusted!> * 2.0           →   <untrusted!>     (scalar lifts cleanly)
"prefix: " ++ a<untrusted!>   →   <untrusted!>     (string concat is "arithmetic" for taint purposes)
```

The exact canonical form of composed taint labels is an open question.
Three options:

1. **Outermost single-`!`**: `<a!> + <b!> → <(a+b)!>`. Once tainted, always
   tainted; one discharge clears it. Probably right.
2. **Preserve all markers**: `<a!> + <b!> → <a!+b!>`. Each origin tracked
   separately. More information, more discharges needed.
3. **Tag union**: `<a!> + <b!> → <(a|b)!>`. Discharge against the union.

Suggested: option 1. The information that matters is "this needs discharge";
the specific origins matter less than "did it get sanitized for the right
sink."

## Opt-out: `.unsafe` variants

Casual scripts shouldn't be forced through the full ceremony for every
`read.ln`. Each tainted stdlib source provides a `.unsafe` variant that
returns plain (untagged) values:

```
std/io:read.ln              →  []const u8<untrusted!>
std/io:read.ln.unsafe       →  []const u8           // opt out, no taint
```

The `.unsafe` suffix carries the right cultural signal — same connotation
as Rust's `unsafe`. "I know what I'm doing; don't track this."

## Permissive sinks via union phantoms

Sinks that genuinely don't care use union phantoms:

```
std/io:print.ln  accepts <untrusted|sanitized>  (or just no phantom restriction)
```

Note: `print.ln`'s signature in particular is TBD. It currently takes a
format string; the taint propagation has to thread through the interpolation
machinery somehow. That's an implementation detail for the stdlib work, not
a hole in the type-system design.

## What the type system enforces vs. what it doesn't

**Enforces:**
- A value from a taint source cannot reach a context-bound sink without
  passing through *some* discharge event matching the right shape
- The discharge event chosen produces the right safe-label for the sink
- HTML-escaped data cannot accidentally flow into a SQL sink
- Arithmetic-derived values inherit the taint of their inputs

**Does NOT enforce:**
- That the discharge function *actually sanitizes correctly*. The author
  is responsible inside the discharge body. If `html_escape` returns the
  input unchanged, the type system trusts it.
- That a `.unsafe` opt-out is justified. Author chose to opt out; the system
  cannot second-guess.
- That `<safe_html>` data isn't *also* an XSS payload (depends on the
  sanitizer's quality).

The accurate marketing claim is: **"compile-time enforcement of the
sanitize-before-sink protocol"** — not "compile-time guarantee of safe
output." Same shape as the existing resource-cleanup story: the type system
enforces that you *called* the right function, not that the function is
correct internally.

## Examples

### SQL injection prevented

```koru
~start = std/io:read.ln
| ln user_input |>
    std/sql:execute(query: user_input)
    //                     ^^^^^^^^^^ ERROR: expected <safe_sql>, got <untrusted!>
```

Fix:

```koru
~start = std/io:read.ln
| ln user_input |>
    std/sanitize:sql_param(user_input)
    | sanitized safe |>
        std/sql:execute(query: safe)   // safe is <safe_sql>; sink accepts
```

### Cross-context confusion caught

```koru
~start = std/io:read.ln
| ln raw |>
    std/sanitize:html_escape(raw)
    | sanitized html_safe |>
        std/sql:execute(query: html_safe)
        //                     ^^^^^^^^^ ERROR: expected <safe_sql>, got <safe_html>
```

The wrong-context bug is caught at compile time, not after a security audit.

### Taint propagation through string concatenation

```koru
~start = std/io:read.ln
| ln user |>
    std/shell:exec(cmd: "rm " ++ user)
    //                  ^^^^^^^^^^^^^ ERROR: expected <safe_shell>, got <untrusted!>
    //                  (concatenation preserves untrusted)
```

Fix:

```koru
~start = std/io:read.ln
| ln user |>
    std/sanitize:shell_arg(user)
    | sanitized arg |>
        std/shell:exec(cmd: "rm " ++ arg)
        //                  ^^^^^^^^^^^^ ERROR: still <untrusted|safe_shell>?
```

Wait — does literal `"rm "` (untainted) concatenated with `arg<safe_shell>`
produce `<safe_shell>` or some taint-mixed label? This is an **open design
question**: how does taint composition handle untainted literals?

Probably: untainted literal `++ safe_shell` should preserve `<safe_shell>`
(literal is dimensionless/origin-less, doesn't introduce taint). But mixing
two *different* safe-labels (e.g., `safe_html ++ safe_sql`) is genuinely a
problem and should reject.

### Permissive logging

```koru
~start = std/io:read.ln
| ln user |>
    std/io:print.ln("got: " ++ user)
    // OK — print.ln accepts <untrusted|sanitized>, doesn't enforce taint
```

If the user prefers strict logging:

```koru
~start = std/io:read.ln
| ln user |>
    std/sanitize:passthrough_unsafe(user)
    | acknowledged safe |>
        std/io:print.ln("got: " ++ safe)
```

The `passthrough_unsafe` discharge is a no-op transition — the author is
explicitly stating "I acknowledge this is untrusted and I'm intentionally
printing it anyway." Makes the safety boundary visible.

## Open design questions

1. **Canonical form for composed `!` labels.** Outermost-single-`!`,
   preserve-all-markers, or tag-union. Affects discharge syntax.
2. **Untainted literal + tainted value composition.** Should `"prefix" ++ x<untrusted!>`
   produce `<untrusted!>` (literal contributes no taint) or some marker
   indicating mixed origin? Probably the former.
3. **Mixing two different safe-labels.** `safe_html ++ safe_sql` — type
   error, or just produces a union? Almost certainly type error; the result
   is meaningful in no context.
4. **The `print.ln` signature.** Currently format-string-based. How does
   taint thread through interpolation? Probably each interpolated argument
   carries its own taint, and `print.ln` accepts union or no constraint.
5. **Stdlib opt-out scope.** Just `.unsafe` for sources, or also a way to
   tell the whole compilation "skip taint tracking for this module"?
   (Equivalent to removing the taint pass via `~std/compiler:coordinate`
   override.)

## Minimal viable stdlib for taint

Initial implementation surface to make the feature shippable:

- **Sources** (`<untrusted!>` producers):
  - `std/io:read.ln` + `.unsafe`
  - `std/io:read.env(key)` + `.unsafe`
  - `std/io:read.file(path)` + `.unsafe`
  - `std/io:read.args.get(idx)` (program args) + `.unsafe`

- **Discharges** (`<untrusted!>` → safe-label):
  - `std/sanitize:html_escape` → `<safe_html>`
  - `std/sanitize:sql_param` → `<safe_sql>`
  - `std/sanitize:shell_arg` → `<safe_shell>`
  - `std/sanitize:url_encode` → `<safe_url>`
  - `std/sanitize:integer_parse` → `<verified>` or `| invalid`
  - `std/sanitize:passthrough_unsafe` → `<safe_console>` (acknowledged passthrough)

- **Sinks** (when/if these stdlib modules exist):
  - `std/http:respond` accepts `<safe_html>`
  - `std/sql:execute` accepts `<safe_sql>`
  - `std/shell:exec` accepts `<safe_shell>`
  - `std/fs:write` accepts `<safe_path>` (with `std/sanitize:path_normalize`)

That's ~12 events. Small enough to ship in days once the underlying pass
exists.

## Implementation sketch

The implementation is almost entirely a **stdlib annotation pass** — the
existing obligation checker already does the gate-on-`!` work. What's needed:

1. **Generalize the obligation checker** to fire on any base type, not just
   pointers/complex. Today it likely has implicit assumptions about working
   on `*Type` shapes. Generalize the dispatch to "any type with a
   `!`-bearing phantom."
2. **Add taint propagation** through arithmetic and string operations. When
   a `!`-bearing label flows through a binary op, the result carries `!`.
   This is one new checker rule, ~50–100 LOC.
3. **Migrate the small stdlib** to use the new labels. ~5 stdlib files
   touched, ~20 lines changed.
4. **Document the convention** so library authors can extend it for their
   own sources/sinks/discharges.

The total implementation is bounded by the small current stdlib. Same shape
as the migration sweep from `[]` to `<>` (118 files, 422 changes, mechanical).

## Why this works

- **One mechanism**: obligation checker, generalized. No new pass strictly
  required — the existing `AutoDischargeInserter` / `PhantomSemanticChecker`
  already does the gating; we just need to make sure it triggers on
  arithmetic-derived `!`-bearing labels and on non-pointer base types.
- **Opacity preserved**: outside the checker, the `!` is just a character in
  a string. AST stays clean.
- **Composes with units**: a value can carry BOTH unit and taint labels
  (e.g., `f64<usd!>`). The units checker fires on the non-`!` part; the
  obligation checker fires on the `!` part. Independent axes.
- **Removable in user-space**: same `~std/compiler:coordinate` override
  story as units.
- **Author-extensible**: nothing about `<safe_html>` is hardcoded. Any
  library can define its own safe-labels and discharge events.

## Why now

The current koru stdlib is **tiny** (5–10 events in active use). Wiring
taint into stdlib boundaries from the start is a one-day job. Doing it
after stdlib growth (say, at 100+ events) becomes a major migration. The
window is now.

## Related

- `UNITS_OF_MEASURE.md` — the parallel pass for dimensional algebra,
  same architectural pattern.
- `COMPILER_ANNOTATIONS.md` — the third bracket-syntax category (`[]` for
  declaration-level metadata, distinct from value-level phantoms).
- `koru_std/compiler.kz:614` — the pluggable compilation pipeline.
- `tests/regression/300_ADVANCED_FEATURES/330_PHANTOM_TYPES/330_009..010`
  — universal/module wildcard metatype tests, the union-phantom support
  this design relies on.
- Blog post: `/blog/phantom-types-resource-safety` on korulang.org (the
  existing obligation-system story this design extends).
